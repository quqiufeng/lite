;;; chez-perfmap.scm — 让任意 Chez AOT 产物自报 code entry，供 perf 归因
;;;
;;; 问题：`compile-file` 的机器码落在 rwxp 匿名段，ELF 里没有符号，perf 只能记成 [anon]。
;;;       外部 profiler（lite 的 perfprobe、perf report）因此看不到热点函数名。
;;; 做法：把每个顶层过程的 code entry + 名字写进 /tmp/perf-<pid>.map（perf 的标准 JIT 接口）。
;;;
;;; 用法（两次：起手一次 + 收尾一次）：
;;;   (load "chez-perfmap.scm")        ; 或把本文件内容内联进程序
;;;   (chez-perfmap-publish!)          ; ① 起手先发一次：边采边符号化的 profiler 才看得见
;;;   ...
;;;   (chez-perfmap-publish!)          ; ② 跑完再发一次覆盖：修正首调重编译的地址漂移
;;;
;;; 为什么必须发两次：map 是 perf 的 JIT 接口，`trace oncpu --sym` 之类在样本到手的
;;; 那一刻就去读表；只在末尾发 → 整个运行期读不到，全部记成 [anon]（这是实测过的老 bug）。
;;; 早发的顾虑是"过程对象首字还没指向代码段"，实测否定：1550 个顶层的纯 Chez 产物，
;;; 起手发布 1550/1550 条已落在可执行段，与收尾发布地址一致率 99.6%
;;; （漂移的只有"自报时还没跑过"的那几个），故早发安全，晚发只用来修准尺寸。
;;;
;;; 覆盖范围：`environment-symbols` 枚举到的是程序的顶层命名空间（含本程序定义 + 内联的库），
;;; 实测 Chez 10.5 AOT 产物约 1970 个过程。lambda/内联展开后的代码没有独立顶层名，
;;; 仍会记成 [anon]（这是 perfmap 机制的固有上限，行级归因请用源码级 profiler）。
;;;
;;; 依赖：仅 Chez 自带过程（environment-symbols / top-level-value / object->reference-address
;;;       / foreign-ref / sort / open-output-file）。需要 (compile-ftype ...) 之外无额外配置。

(define (chez-perfmap-entry p)
  ;; 过程对象首字 = code entry；低 3 位是对象标记，掩掉。
  (foreign-ref 'uptr
               (bitwise-and (object->reference-address p) (bitwise-not 7))
               0))

(define (chez-perfmap-safe-value s)
  ;; 未绑定 / 非变量（module 等）绑定会抛普通条件，guard 兜住即当不存在。
  (guard (e (#t #f)) (top-level-value s)))

(define (chez-perfmap-publish!)
  (let* ((syms (environment-symbols (interaction-environment)))
         (rows (let loop ((s syms) (acc '()))
                 (if (null? s)
                     acc
                     (let ((p (chez-perfmap-safe-value (car s))))
                       (loop (cdr s)
                             (if (procedure? p)
                                 (cons (cons (chez-perfmap-entry p)
                                             (symbol->string (car s)))
                                       acc)
                                 acc))))))
         (sorted (sort (lambda (a b) (< (car a) (car b))) rows))
         (port (open-output-file
                (string-append "/tmp/perf-" (number->string (get-process-id)) ".map")
                'replace)))
    (let loop ((l sorted) (last -1))
      (cond
        ((null? l) (void))
        ;; 多个名字指向同一入口（别名/包装）只留第一个，避免归因被后者覆盖
        ((= (car (car l)) last) (loop (cdr l) last))
        (else
         (let* ((cur (car l))
                (rest (cdr l))
                (start (car cur))
                ;; 相邻入口间距 ≈ 本函数代码长度（末项按 0x800 估），夹在 0x20..0x2000
                (nxt (if (null? rest) (+ start #x800) (car (car rest))))
                (gap (- nxt start))
                (size (if (or (< gap #x20) (> gap #x2000)) #x100 gap)))
           (fprintf port "~x ~x ~a~n" start size (cdr cur))
           (loop rest start)))))
    (close-port port)))

;;; 便捷别名
(define publish-perfmap! chez-perfmap-publish!)
