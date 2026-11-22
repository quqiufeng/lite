/* perfprobe: in-process CPU sampler with attribution.
 * lite_helper(input_json) -> output_json
 * input : {"argv":["prog","arg1"],"freq":99,"seconds":60,"top":20,"show_output":false}
 * output: {"ok":1,"samples":N,"lost":0,"exit":0,"objects":[...],"symbols":[...]}
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <elf.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

/* ---------- growable buffer ---------- */
typedef struct { char *p; size_t len, cap; } Buf;
static void binit(Buf *b){ b->cap=8192; b->len=0; b->p=(char*)malloc(b->cap); b->p[0]=0; }
static void bput(Buf *b, const char *s, size_t n){
  if (b->len+n+1 > b->cap){ while (b->len+n+1 > b->cap) b->cap*=2; b->p=(char*)realloc(b->p,b->cap); }
  memcpy(b->p+b->len, s, n); b->len+=n; b->p[b->len]=0;
}
static void bputs(Buf *b, const char *s){ bput(b,s,strlen(s)); }
static void bprintf(Buf *b, const char *fmt, ...){
  char tmp[4096]; va_list ap; va_start(ap,fmt);
  int n=vsnprintf(tmp,sizeof tmp,fmt,ap); va_end(ap);
  if (n>0) bput(b,tmp,(size_t)n<(sizeof tmp)?(size_t)n:sizeof tmp-1);
}
static void bjstr(Buf *b, const char *s){
  bput(b,"\"",1);
  for (const unsigned char *q=(const unsigned char*)s; *q; q++){
    if (*q=='"'||*q=='\\'){ char e[2]={'\\',(char)*q}; bput(b,e,2); }
    else if (*q=='\n') bput(b,"\\n",2);
    else if (*q=='\t') bput(b,"\\t",2);
    else if (*q<0x20) bprintf(b,"\\u%04x",*q);
    else bput(b,(const char*)q,1);
  }
  bput(b,"\"",1);
}

/* ---------- tiny JSON reader (input is ours) ---------- */
static const char *jfind(const char *s, const char *key){
  char pat[128]; snprintf(pat,sizeof pat,"\"%s\"",key);
  return strstr(s,pat);
}
static char *jstr(const char **pp){
  const char *p=*pp; if (*p!='"') return NULL; p++;
  size_t cap=256,len=0; char *o=(char*)malloc(cap);
  while (*p && *p!='"'){
    char c=*p;
    if (c=='\\' && p[1]){ p++; c=*p; if(c=='n')c='\n'; else if(c=='t')c='\t'; else if(c=='r')c='\r'; }
    o[len++]=c; p++;
    if (len+2>cap){ cap*=2; o=(char*)realloc(o,cap); }
  }
  if (*p=='"') p++;
  o[len]=0; *pp=p; return o;
}
static double jnum(const char *s, const char *key, double dflt){
  const char *p=jfind(s,key); if(!p) return dflt;
  p=strchr(p,':'); if(!p) return dflt;
  return strtod(p+1,NULL);
}
static long jbool(const char *s, const char *key, long dflt){
  const char *p=jfind(s,key); if(!p) return dflt;
  p=strchr(p,':'); if(!p) return dflt; p++;
  while (*p==' ') p++;
  return strncmp(p,"true",4)?dflt:1;
}

/* ---------- ELF symbol tables (kept mapped: names point into the image) ---------- */
typedef struct { unsigned long v, sz; unsigned int noff; } Sym;
typedef struct {
  char path[512]; Sym *s; int n; char *str; size_t strsz;
  unsigned char *base; int ok;
} ElfT;
static ElfT *g_elf; static int g_nelf, g_capelf;

static int symcmp(const void *a, const void *b){
  unsigned long x=((const Sym*)a)->v, y=((const Sym*)b)->v;
  return x<y?-1:(x>y?1:0);
}

static ElfT *elf_get(const char *path){
  for (int i=0;i<g_nelf;i++) if (!strcmp(g_elf[i].path,path)) return &g_elf[i];
  if (g_nelf==g_capelf){ g_capelf = g_capelf? g_capelf*2 : 8;
    g_elf=(ElfT*)realloc(g_elf,(size_t)g_capelf*sizeof(ElfT)); }
  ElfT *e=&g_elf[g_nelf++]; memset(e,0,sizeof *e);
  snprintf(e->path,sizeof e->path,"%s",path);
  int fd=open(path,O_RDONLY); if(fd<0) return e;
  struct stat st;
  if (fstat(fd,&st)<0 || st.st_size<64){ close(fd); return e; }
  size_t fsz=(size_t)st.st_size;
  unsigned char *d=(unsigned char*)mmap(NULL,fsz,PROT_READ,MAP_PRIVATE,fd,0); close(fd);
  if (d==MAP_FAILED) return e;
  e->base=d;
  if (!(d[0]==0x7f&&d[1]=='E'&&d[2]=='L'&&d[3]=='F'&&d[4]==2)) return e;
  Elf64_Ehdr *eh=(Elf64_Ehdr*)d;
  size_t shneed=(size_t)eh->e_shoff + (size_t)eh->e_shnum*sizeof(Elf64_Shdr);
  if (!eh->e_shoff || eh->e_shentsize!=sizeof(Elf64_Shdr) || shneed>fsz) return e;
  Elf64_Shdr *sh=(Elf64_Shdr*)(d+eh->e_shoff);
  int pick=-1, pickdyn=-1;
  for (int i=0;i<eh->e_shnum;i++){
    if (sh[i].sh_type==SHT_SYMTAB && pick<0) pick=i;
    if (sh[i].sh_type==SHT_DYNSYM && pickdyn<0) pickdyn=i;
  }
  if (pick<0) pick=pickdyn;
  if (pick<0) return e;
  Elf64_Shdr *ss=&sh[pick];
  if (ss->sh_entsize!=sizeof(Elf64_Sym) || ss->sh_link>=eh->e_shnum) return e;
  if (ss->sh_offset+ss->sh_size>fsz) return e;
  Elf64_Shdr *ts=&sh[ss->sh_link];
  if (ts->sh_offset+ts->sh_size>fsz) return e;
  size_t cnt=ss->sh_size/sizeof(Elf64_Sym);
  Elf64_Sym *sy=(Elf64_Sym*)(d+ss->sh_offset);
  e->s=(Sym*)malloc((cnt?cnt:1)*sizeof(Sym)); e->n=0;
  for (size_t i=0;i<cnt;i++){
    if (ELF64_ST_TYPE(sy[i].st_info)!=STT_FUNC) continue;
    if (!sy[i].st_value || !sy[i].st_size) continue;
    e->s[e->n].v=sy[i].st_value; e->s[e->n].sz=sy[i].st_size;
    e->s[e->n].noff=sy[i].st_name; e->n++;
  }
  if (e->n>0) qsort(e->s,(size_t)e->n,sizeof(Sym),symcmp);
  e->str=(char*)(d+ts->sh_offset); e->strsz=ts->sh_size;
  e->ok = e->n>0;
  return e;
}

static const char *elf_sym(ElfT *e, unsigned long off){
  if (!e->ok) return NULL;
  int lo=0, hi=e->n-1, best=-1;
  while (lo<=hi){ int mid=(lo+hi)/2;
    if (e->s[mid].v<=off){ best=mid; lo=mid+1; } else hi=mid-1; }
  if (best<0) return NULL;
  if (off < e->s[best].v + e->s[best].sz){
    unsigned int no=e->s[best].noff;
    if (no < e->strsz) return e->str+no;
  }
  return NULL;
}

/* ---------- /proc/pid/maps snapshot (merged, deduped) ---------- */
typedef struct { unsigned long start,end,off; char perms[8]; char path[512]; } MapR;
#define MAXMAPS 1024
static MapR g_map[MAXMAPS]; static int g_nmap;

static void maps_read(pid_t pid){
  char p[64]; snprintf(p,sizeof p,"/proc/%d/maps",pid);
  FILE *f=fopen(p,"r"); if(!f) return;
  char line[1400];
  while (fgets(line,sizeof line,f)){
    unsigned long s=0,e=0,o=0; char perms[8]; char path[512]; path[0]=0;
    int n=sscanf(line,"%lx-%lx %7s %lx %*s %*s %511s",&s,&e,perms,&o,path);
    if (n<4 || n<1) continue;
    int dup=0;
    for (int i=0;i<g_nmap;i++) if (g_map[i].start==s){ dup=1; break; }
    if (dup || g_nmap>=MAXMAPS) continue;
    MapR *m=&g_map[g_nmap++];
    m->start=s; m->end=e; m->off=o; snprintf(m->perms,8,"%s",perms);
    snprintf(m->path,512,"%s",(n>=5)?path:"");
  }
  fclose(f);
}

static const char *base_name(const char *p){
  const char *s=strrchr(p,'/');
  return s? s+1 : p;
}

/* ---------- sampling + attribution ---------- */
typedef struct { char obj[192]; char sym[192]; long cnt; } Hit;
#define MAXHITS 8192
static Hit g_hit[MAXHITS]; static int g_nhit;

static void hit_add(const char *obj, const char *sym){
  for (int i=0;i<g_nhit;i++)
    if (!strcmp(g_hit[i].obj,obj) && !strcmp(g_hit[i].sym,sym)){ g_hit[i].cnt++; return; }
  if (g_nhit>=MAXHITS) return;
  Hit *h=&g_hit[g_nhit++];
  snprintf(h->obj,sizeof h->obj,"%s",obj);
  snprintf(h->sym,sizeof h->sym,"%s",sym);
  h->cnt=1;
}
typedef struct { char obj[192]; long cnt; } ObjTot;
static ObjTot g_obj[256]; static int g_nobj;
static void obj_add(const char *obj){
  for (int i=0;i<g_nobj;i++) if (!strcmp(g_obj[i].obj,obj)){ g_obj[i].cnt++; return; }
  if (g_nobj>=256) return;
  snprintf(g_obj[g_nobj].obj,sizeof g_obj[0].obj,"%s",obj);
  g_obj[g_nobj].cnt=1; g_nobj++;
}

static int hitcmp(const void *a, const void *b){
  long x=((const Hit*)a)->cnt, y=((const Hit*)b)->cnt;
  return x<y?1:(x>y?-1:0);
}
static int objcmp(const void *a, const void *b){
  long x=((const ObjTot*)a)->cnt, y=((const ObjTot*)b)->cnt;
  return x<y?1:(x>y?-1:0);
}

static int peo(struct perf_event_attr *a, pid_t pid){
  return (int)syscall(__NR_perf_event_open, a, pid, -1, -1, 0);
}

#define RING_SZ (1u<<20)

/* drain ring into ips[]; returns count appended */
static int drain(void *buf, unsigned long *ips, int nips, int cap, long *lost){
  struct perf_event_mmap_page *meta=(struct perf_event_mmap_page*)buf;
  __sync_synchronize();
  unsigned long head=meta->data_head, tail=meta->data_tail;
  char *data=(char*)buf + 4096;
  int added=0;
  while (tail < head){
    struct perf_event_header *h=(struct perf_event_header*)(data + (tail & (RING_SZ-1)));
    if (h->size==0) break;
    if (h->type==PERF_RECORD_SAMPLE){
      unsigned long ip=*(unsigned long*)((char*)(h+1));
      if (nips+added < cap) ips[nips+added]=ip;
      added++;
    } else if (h->type==PERF_RECORD_LOST) (*lost)++;
    tail += h->size;
    /* tail may wrap; recompute linear offset */
    if (tail + 4096 < head && (tail & (RING_SZ-1)) == 0) { }
  }
  meta->data_tail=tail;
  return added;
}

static char *run_probe(const char *input, size_t inlen){
  (void)inlen;
  Buf out; binit(&out);

  /* argv */
  char *args[64]; int nargs=0;
  const char *ap=jfind(input,"argv");
  if (!ap){ bputs(&out,"{\"ok\":0,\"error\":\"missing argv\"}"); return out.p; }
  ap=strchr(ap,'['); if(!ap){ bputs(&out,"{\"ok\":0,\"error\":\"bad argv\"}"); return out.p; }
  ap++;
  while (*ap && *ap!=']' && nargs<63){
    while (*ap==' '||*ap==','||*ap=='\n'||*ap=='\t') ap++;
    if (*ap=='"'){ char *s=jstr(&ap); if(s) args[nargs++]=s; }
    else break;
  }
  args[nargs]=NULL;
  if (!nargs){ bputs(&out,"{\"ok\":0,\"error\":\"empty argv\"}"); return out.p; }

  double freq=jnum(input,"freq",99.0); if(freq<1) freq=1; if(freq>5000) freq=5000;
  double seconds=jnum(input,"seconds",600.0); if(seconds<=0) seconds=600.0;
  int top=(int)jnum(input,"top",20); if(top<1) top=20; if(top>200) top=200;
  int show=jbool(input,"show_output",0);

  /* child; a CLOEXEC pipe reports exec failures back (close-on-exec => EOF on success) */
  int ep[2];
  if (pipe(ep)!=0){ bprintf(&out,"{\"ok\":0,\"error\":\"pipe: %s\"}",strerror(errno)); return out.p; }
  fcntl(ep[0],F_SETFL,O_NONBLOCK);
  fcntl(ep[1],F_SETFD,FD_CLOEXEC);
  pid_t pid=fork();
  if (pid==0){
    close(ep[0]);
    int dn=open("/dev/null",O_WRONLY);
    if (dn>=0){ dup2(dn,1); if(!show) dup2(dn,2); }
    execvp(args[0],args);
    int e=errno;
    if (write(ep[1],&e,sizeof e)!=(ssize_t)sizeof e) _exit(127);
    _exit(127);
  }
  if (pid<0){ close(ep[0]); close(ep[1]);
    bprintf(&out,"{\"ok\":0,\"error\":\"fork: %s\"}",strerror(errno)); return out.p; }
  close(ep[1]);

  usleep(3000);
  { int ee=0; ssize_t rn=read(ep[0],&ee,sizeof ee);
    if (rn==(ssize_t)sizeof ee){
      close(ep[0]); waitpid(pid,NULL,0);
      bprintf(&out,"{\"ok\":0,\"error\":\"exec %s\"}",strerror(ee)); return out.p; }
    close(ep[0]);
  }
  struct perf_event_attr a; memset(&a,0,sizeof a);
  a.type=PERF_TYPE_SOFTWARE;
  a.config=PERF_COUNT_SW_CPU_CLOCK;
  a.size=sizeof a;
  a.sample_period=(unsigned long long)(1e9/freq);
  a.sample_type=PERF_SAMPLE_IP;
  a.disabled=1;
  a.exclude_kernel=1;
  a.exclude_hv=1;
  a.wakeup_events=1;
  int fd=peo(&a,pid);
  if (fd<0){
    int e=errno;
    int st=0; pid_t wr=waitpid(pid,&st,WNOHANG);
    if (wr==pid){
      bprintf(&out,"{\"ok\":0,\"samples\":0,\"exit\":%d,\"error\":\"target exited before sampling started\"}",WIFEXITED(st)?WEXITSTATUS(st):-1);
      return out.p;
    }
    kill(pid,9); waitpid(pid,NULL,0);
    bprintf(&out,"{\"ok\":0,\"error\":\"perf_event_open: %s (paranoid=%d)\"}",strerror(e),
      ({ int v=-1; FILE*f=fopen("/proc/sys/kernel/perf_event_paranoid","r"); if(f){ if(fscanf(f,"%d",&v)!=1) v=-1; fclose(f);} v; }));
    return out.p;
  }
  size_t ring=(size_t)RING_SZ+4096;
  void *buf=mmap(NULL,ring,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  if (buf==MAP_FAILED){
    kill(pid,9); waitpid(pid,NULL,0); close(fd);
    bprintf(&out,"{\"ok\":0,\"error\":\"mmap: %s\"}",strerror(errno)); return out.p;
  }
  g_nmap=0; g_nhit=0; g_nobj=0;
  maps_read(pid);
  ioctl(fd,PERF_EVENT_IOC_ENABLE,0);

  int cap=600000; unsigned long *ips=(unsigned long*)malloc((size_t)cap*sizeof(unsigned long));
  int nips=0; long lost=0;
  struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
  double spent=0; int status=0; int it=0;
  for (;;){
    struct pollfd pf={.fd=fd,.events=POLLIN};
    poll(&pf,1,50);
    nips += drain(buf,ips,nips,cap,&lost);
    if ((++it & 3)==0) maps_read(pid);
    pid_t r=waitpid(pid,&status,WNOHANG);
    if (r==pid){ nips += drain(buf,ips,nips,cap,&lost); break; }
    clock_gettime(CLOCK_MONOTONIC,&t1);
    spent=(double)(t1.tv_sec-t0.tv_sec)+(double)(t1.tv_nsec-t0.tv_nsec)/1e9;
    if (spent>seconds){ kill(pid,9); waitpid(pid,&status,0); break; }
  }
  ioctl(fd,PERF_EVENT_IOC_DISABLE,0);
  maps_read(pid);
  munmap(buf,ring); close(fd);
  if (nips>cap) nips=cap;

  /* attribute */
  for (int i=0;i<nips;i++){
    unsigned long ip=ips[i];
    MapR *m=NULL;
    for (int k=0;k<g_nmap;k++)
      if (ip>=g_map[k].start && ip<g_map[k].end){ m=&g_map[k]; break; }
    const char *obj = (m && m->path[0]) ? base_name(m->path) : "[anon]";
    char obuf[192]; snprintf(obuf,sizeof obuf,"%s",obj);
    const char *sym=NULL;
    if (m && m->path[0]=='/'){
      unsigned long off = ip - m->start + m->off;
      ElfT *e=elf_get(m->path);
      sym=elf_sym(e,off);
    }
    if (!sym){
      if (m && m->path[0])      sym = "[nosym]";           /* file-backed, stripped */
      else if (m && strchr(m->perms,'x')) sym = "[anon:exec]";
      else                      sym = "[data]";
    }
    hit_add(obuf,sym);
    obj_add(obuf);
  }
  free(ips);
  qsort(g_hit,(size_t)g_nhit,sizeof(Hit),hitcmp);
  qsort(g_obj,(size_t)g_nobj,sizeof(ObjTot),objcmp);

  int code = WIFEXITED(status)? WEXITSTATUS(status) : -1;
  double anon=0;
  for (int i=0;i<g_nobj;i++) if (!strcmp(g_obj[i].obj,"[anon]")) anon=100.0*(double)g_obj[i].cnt/(double)(nips?nips:1);
  bprintf(&out,"{\"ok\":1,\"samples\":%d,\"lost\":%ld,\"exit\":%d,\"seconds\":%.3f,"
               "\"maps\":%d,\"freq\":%.0f,\"anon_pct\":%.2f,",nips,lost,code,spent,g_nmap,freq,anon);
  bputs(&out,"\"objects\":[");
  { int lim=g_nobj<top?g_nobj:top;
    for (int i=0;i<lim;i++){
      if(i) bputs(&out,",");
      bprintf(&out,"{\"name\":"); bjstr(&out,g_obj[i].obj);
      bprintf(&out,",\"samples\":%ld,\"pct\":%.1f}",g_obj[i].cnt,
        nips? 100.0*(double)g_obj[i].cnt/(double)nips : 0.0);
    } }
  bputs(&out,"],\"symbols\":[");
  { int lim=g_nhit<top?g_nhit:top;
    for (int i=0;i<lim;i++){
      if(i) bputs(&out,",");
      bprintf(&out,"{\"symbol\":"); bjstr(&out,g_hit[i].sym);
      bprintf(&out,",\"object\":"); bjstr(&out,g_hit[i].obj);
      bprintf(&out,",\"samples\":%ld,\"pct\":%.2f}",g_hit[i].cnt,
        nips? 100.0*(double)g_hit[i].cnt/(double)nips : 0.0);
    } }
  bputs(&out,"]}");
  return out.p;
}

char *lite_helper(const char *input){
  return run_probe(input?input:"{}", input?strlen(input):2);
}
void lite_helper_free(char *out){ free(out); }
