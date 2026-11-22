;;; chez-perfmap.scm — 让任意 Chez AOT 产物自报 code entry，供 perf 归因
;;;
;;; 问题：`compile-file` 的机器码落在 rwxp 匿名段，ELF 里没有符号，perf 只能记成 [anon]。
;;;       外部 profiler（lite 的 perfprobe、perf report）因此看不到热点函数名。
;;; 做法：把每个顶层过程的 code entry + 名字写进 /tmp/perf-<pid>.map（perf 的标准 JIT 接口）。
;;;
;;; 用法（两行）：
;;;   (load "chez-perfmap.scm")        ; 或把本文件内容内联进程序
;;;   ...
;;;   (chez-perfmap-publish!)          ; 放在 (main) *之后*，即程序真正跑过一轮再报
;;;
;;; 为什么必须放在最后：过程对象首字在首次执行/装载前可能指向堆上的字节码，
;;; 而不是代码段。依次序晚写只影响 map 的写入时刻，不影响采样（profiler 收尾统一归因）。
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
