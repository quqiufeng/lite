# Linux 7.2.12 — 页缓存读路径（buffered read）

> 索引：`/opt/code_caches/linux_7212_cache`（chunks 287M / vectors jina / dataflow 796M / kv 7.3G），源码 `/opt/linux/src/linux-7.2.12`。
> 本机运行内核即 `7.2.12-rtx3080-20261025`，所以标 `[verified]` 的链条来自**真机 function_graph** 抓的调用树，不是推断。

## 1. 一句话

`read(2)` 一次 buffered 读 = **VFS `read_iter` → `filemap_read` 拿一批 folio → 命中就拷贝、缺失就 `read_pages` 交给文件系统填页**；`address_space` 是所有文件系统共用的契约面（`i_pages` 存页、`a_ops->read_folio` 负责缺页回填）。

## 2. 主图（[static] 结构 + [verified] 运行树）

```
read(2)
 └─ vfs_read → file->f_op->read_iter
     └─ generic_file_read_iter / btrfs_file_read_iter / f2fs_... (10 个入口共用 filemap_read)
         └─ filemap_read()                          mm/filemap.c:2783   [static 扇入=10]
             ├─ filemap_get_pages()                 mm/filemap.c:2682   [static]
             │   ├─ filemap_get_read_batch()        ← 命中快路径          [verified] 1–2 µs
             │   │    └─ __rcu_read_lock/unlock()                       [verified]
             │   ├─ filemap_readahead()             → page_cache_sync/async_ra
             │   ├─ filemap_create_folio()          → filemap_add_folio(i_pages)
             │   └─ filemap_update_page()           → 锁 + 等 uptodate
             ├─ pos_same_folio / folio_pos / folio_size
             └─ copy_folio_to_iter()                ← 拷到用户 buffer

缺页回填（miss 路径，[verified] 真机抓取）：
 read_pages()
  └─ ext4_readahead()                        ← /opt 位于 ext4
      └─ ext4_mpage_readpages()
          ├─ ext4_map_blocks() → ext4_es_lookup_extent() / __check_block_validity()
          ├─ bio_alloc_bioset() → bio_associate_blkg()
          └─ bio_add_folio()  → 提交后 folio 置 uptodate → 唤醒 filemap_update_page 的等待者
```

单页/元数据读（非 readahead 主干）：

```
do_read_cache_folio()   mm/filemap.c:4098   callers: read_cache_folio / mapping_read_folio_gfp / do_read_cache_page
  ├─ filemap_get_folio()      命中即返回
  ├─ mapping_align_index() / mapping_min_folio_order()   大 folio 对齐
  ├─ filemap_add_folio()      未命中先挂进 i_pages
  ├─ folio_trylock() / folio_test_uptodate()
  └─ filemap_read_folio()     → a_ops->read_folio → 失败时标 error 并移除
```

## 3. 组件表

| 组件 | 位置 | 职责 | 扇入/扇出 |
|---|---|---|---|
| `filemap_read` | mm/filemap.c:2783 | buffered 读总调度：分批、拷出、更新 f_pos/atime | 扇入 10（btrfs/netfs/blkdev/erofs/cifs/f2fs/afs/generic/…） |
| `filemap_get_pages` | :2682 | 一次凑齐 folio_batch，命中优先，缺失才建页/触发 RA | 扇入 2（read / splice_read） |
| `filemap_get_read_batch` | — | xarray 批量取已 uptodate 的 folio（最热路径） | [verified] 1–2 µs |
| `filemap_readahead` | :2668 | 缺失页交给预读（sync/async ra） | 索引无 callee（内联） |
| `filemap_create_folio` / `filemap_add_folio` | — | 分配 folio 并插入 mapping->i_pages | 写 i_pages |
| `do_read_cache_folio` | :4098 | 单页同步读（元数据/链接/配额） | 扇入 3 |
| `address_space_operations->read_folio` | 各 FS | 把磁盘块填进 folio | 间接调用，索引不可见 |
| `read_pages` → `ext4_readahead` → `ext4_mpage_readpages` | mm/readahead.c, fs/ext4 | 预读窗口成批发 bio | [verified] |
| `netfs_read_folio` / `iomap_bio_read_folio` / `block_read_full_folio` | fs/netfs, fs/iomap, fs/buffer.c | 三类通用回填：网络 fs / iomap fs / get_block fs | 横向固定 |

`a_ops->read_folio` 横向分布（[static]，语义搜索命中）：
- **`block_read_full_folio(folio, <fs>_get_block)`**：omfs / bfs / adfs / hfs / efs / befs / affs —— 一行包装，靠 get_block 回调
- **iomap**：`zonefs_read_folio` → `iomap_bio_read_folio`；`ntfs_read_folio` → `iomap_read_folio_ctx` + 自定义 bio ops
- **netfs**：`netfs_read_folio`（cifs/afs/9p 共用，自带 cache + 重试）
- **私有**：`hostfs`（直接 read_file）、`orangefs`（iov_iter + 先 launder dirty）

## 4. 数据流契约（[static] 结构定义）

`struct address_space`（include/linux/fs.h:472）：`host` inode、`i_pages` **xarray**（读路径唯一查找结构）、`invalidate_lock`、`nrpages`、`writeback_index`、`a_ops`（回填/写回/释放回调表）、`i_mmap`、`wb_err`。

`struct readahead_control`（include/linux/pagemap.h:1345）：`file`、`mapping`、`ra`、`_index`、`_nr_pages`、`_batch_count`、`dropbehind`、`_workingset`、`_pflags` —— 私有字段必须走 `readahead_index()/readahead_count()` 访问器。

不变式：
1. folio 进 `i_pages` 前必须已加锁（`filemap_add_folio` 检查）；失败路径必须从 xarray 摘除。
2. `read_folio` 成功 = folio uptodate 且解锁；失败 = 标 error、从 xarray 删除、必要时 `mapping_set_error`。
3. 读路径不持 `invalidate_lock`（写/截断侧持）。

## 5. 实跑与测试

- **真机取证**（本机 7.2.12，免密 sudo + tracefs）：
  - 命中：`filemap_get_pages → filemap_get_read_batch → __rcu_read_lock/unlock`，1.2–1.9 µs
  - 缺失：`read_pages → ext4_readahead → ext4_mpage_readpages → ext4_map_blocks → bio_alloc_bioset → bio_add_folio`（实读 `fs/btrfs/ctree.c` 128 KiB；`/opt` 实际在 **ext4**）
- **测试场景**：`tools/testing/selftests/cachestat` 覆盖 page cache 统计；`--file test` 语义过滤返回 0 → selftests 不在索引里。
- 内核树未构建（无 `.config`、无 `vmlinux`），故未做"编译后跑单测"；有 `qemu-system-x86_64` + `bpftrace`，需要时可 `make defconfig` 走 QEMU。

## 6. 索引缺口

| 缺口 | 现象 | 影响 |
|---|---|---|
| `dataflow` 的 `vars` 键缺结构字段 | `dataflow i_pages` → 0 命中；`funcs` 键正常（`filemap_get_pages` 20 变量） | 跨函数字段流查不到 |
| 调用图缺内联 | `filemap_readahead` callers 1、callees 0 | 路径在 mm/readahead.c 处断链 |
| 调用图缺间接调用 | `a_ops->read_folio` 不出现在任何路径 | 横向表靠语义搜索补 |
| selftests 未索引 | `--file test` 空 | Phase 6 只能靠 ls |

## 7. 下一步

1. **写回路径**（`writepages` → `iomap_writepages` / `block_write_full_folio`）：与读路径共用 `address_space`，扇入同样高。
2. **readahead 窗口逻辑**（`page_cache_ra_unbounded` / `page_cache_async_ra`，均在 available_filter_functions）：可直接 function_graph 抓窗口演进。
3. **补 dataflow vars 键**：`import --only_dataflow` 重跑。
