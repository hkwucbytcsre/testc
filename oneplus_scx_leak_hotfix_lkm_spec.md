# OnePlus / Oplus SCX per-task 内存泄漏 LKM Hotfix 实现规范

> **实现状态（2026-08-10）：** 本文保留最初的双 kretprobe 方案作为历史设计记录。生产版 v2 已改用目标内核导出的 `android_vh_free_task` vendor hook，在 `free_task()` 的统一最终释放点回收 `task->scx`；不再依赖 kprobe/kretprobe。当前实现与验证要求以 `README.md` 和 `docs/superpowers/specs/2026-08-08-scx-leak-hotfix-design.md` 为准。

> 文档用途：交给编码智能体/内核开发者实现一个 **Loadable Kernel Module (LKM)**，在不重编整颗内核的前提下，为 OnePlus/Oplus 部分 `CONFIG_SLIM_SCHED + sched_ext/SCX` 内核补上 `task_struct::scx` 的缺失释放逻辑。
>
> 首要目标平台：**OnePlus MT6989 / Ace 5 竞速版对应源码分支**
>
> 仓库：`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989`
>
> 目标分支：`oneplus/mt6989_v_15.0.2_ace5_race`
>
> 本规范优先追求：**正确性 > 通用性 > 功能数量**。任何无法确认生命周期/ABI 的情况必须 fail closed，禁止“猜 offset 后强行 free”。

---

## 1. 背景与根因

目标内核将上游原本应该内嵌于 `task_struct` 的：

```c
struct sched_ext_entity scx;
```

改成了 KABI 指针：

```c
#ifdef CONFIG_SLIM_SCHED
ANDROID_KABI_USE(2, unsigned long sched_prop);
ANDROID_KABI_USE(3, struct sched_ext_entity *scx);
#endif
```

源码位置：

- `include/linux/sched.h`
- MT6989 分支约 L1468-L1475

源码：

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/include/linux/sched.h`

与此同时，`scx_pre_fork()` 对每个新 task 动态分配：

```c
void scx_pre_fork(struct task_struct *p)
{
    p->scx = kmalloc(sizeof(struct sched_ext_entity), GFP_KERNEL);
    if (!p->scx)
        goto lock;

    ...
}
```

MT6989 源码位置：

- `kernel/sched/ext.c`
- 约 L2128-L2156

源码：

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/kernel/sched/ext.c`

实机 tracing 已确认该分配：

```text
call_site = scx_pre_fork+0x2c/0x174
bytes_req = 232
bytes_alloc = 256
```

即每个 task 对 `kmalloc-256` slab 产生一个对象。

### 1.1 正常 task 销毁路径缺失 free

正常生命周期：

```text
__put_task_struct(tsk)
    -> sched_ext_free(tsk)
    -> ...
    -> free_task(tsk)
    -> free_task_struct(tsk)
```

`__put_task_struct()` 在 MT6989 `kernel/fork.c` 中明确先调用：

```c
sched_ext_free(tsk);
```

但目标源码中的 `sched_ext_free()` 仅执行：

```c
list_del_init(&p->scx->tasks_node);

if (p->scx->flags &
    (SCX_TASK_OPS_PREPPED | SCX_TASK_OPS_ENABLED)) {
    ...
    scx_ops_disable_task(p);
}
```

随后直接返回，没有：

```c
kfree(p->scx);
```

源码位置：

- `kernel/sched/ext.c`
- 约 L2199-L2218

### 1.2 fork 失败路径同样缺失 free

fork 失败时：

```text
copy_process()
    -> sched_cancel_fork(p)
       -> scx_cancel_fork(p)
    -> ...
    -> delayed_free_task(p)
    -> free_task(p)
```

目标源码：

```c
void scx_cancel_fork(struct task_struct *p)
{
    if (scx_enabled())
        scx_ops_disable_task(p);

    percpu_up_read(&scx_fork_rwsem);
}
```

同样没有：

```c
kfree(p->scx);
```

源码位置：

- `kernel/sched/ext.c`
- 约 L2192-L2197

`copy_process()` 失败路径中 `sched_cancel_fork(p)` 后继续普通 task cleanup，最终进入 `delayed_free_task(p)`；没有其它 SCX destructor。

源码：

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/kernel/fork.c`

---

## 2. 实机证据摘要

目标 MT6989 设备已经动态验证：

```text
tasks created since boot = 3,381,857
kmalloc-256 active       = 3,394,096
currently live threads   = 8,813
task_struct active       = 8,928
```

同窗口测试：

```text
new tasks       = 2344
kmalloc-256 net = 2336
```

即 task creation 与 `kmalloc-256` active growth 近似 1:1。

对 `scx_pre_fork()` 分配指针做生命周期跟踪：

```text
tracked = 36
freed   = 0
remain  = 36
```

设备曾出现：

```text
SUnreclaim ≈ 1.32 GiB
kmalloc-256 ≈ 800~830 MiB
```

以及严重物理碎片：

```text
compact_memory 后：
Node 0, zone Normal 43224 14695 2395 67 0 0 0 0 0 0 0
```

在仍有约 323 MiB 空闲页时：

- order-4 (64 KiB) 及以上连续物理块为 0；
- extfrag_index order-4+ 约 `0.917 ... 0.999`；
- 30 秒观测到约 631k 次 `mm_page_alloc_extfrag`。

因此本 LKM 的目标不仅是降低 slab 占用，还要阻止不可回收小对象长期累积对物理页布局造成持续破坏。

---

## 3. LKM 的目标

### 3.1 必须实现

LKM 必须：

1. 在 **原内核最后一次合法使用 `p->scx` 之后**释放 `p->scx`。
2. 覆盖：
   - 正常 task 最终销毁；
   - fork/clone 失败后的 cancel 路径。
3. 对 `NULL` 安全。
4. 防止 double-free。
5. 不替换 `scx_pre_fork()`。
6. 不修改 SCX 调度算法。
7. 不尝试在线扫描并回收已经失去 ownership 的历史泄漏对象。
8. 可以在 Android `post-fs-data` 阶段加载，并长期常驻。
9. 对不匹配的 kernel/source/config 必须拒绝工作，而不是猜测结构偏移。

### 3.2 非目标

v1 不负责：

- 修复 `scx_pre_fork()` 分配失败后错误继续执行的问题；
- 修改 SCX/BPF scheduler 行为；
- 回收 module load 之前已经死亡 task 遗留且无法定位的 orphan 对象；
- 支持未知闭源内核；
- hook `kmalloc()` / `kfree()` 全局路径；
- 通过扫描 `kmalloc-256` slab 猜测对象；
- 使用硬编码 KASLR 地址。

---

## 4. 首选实现架构：双 kretprobe teardown hotfix

### 4.1 为什么首选 kretprobe

不要在：

```text
scx_pre_fork()
```

入口阻止分配，也不要在：

```text
sched_ext_free()
scx_cancel_fork()
```

入口直接 `kfree()`。

原因：两个函数自身仍会访问 `p->scx`。

最符合源代码修复语义的位置是：

```text
sched_ext_free() RETURN
scx_cancel_fork() RETURN
```

即原内核完成全部 SCX cleanup 后、caller 恢复执行前补上 destructor。

因此 v1 **首选 `register_kretprobe()`**。

### 4.2 前置条件

编码前/运行前必须检查：

```sh
zcat /proc/config.gz | grep -E \
'CONFIG_(MODULES|MODULE_UNLOAD|MODVERSIONS|KPROBES|KRETPROBES|SLIM_SCHED|SCHED_CLASS_EXT)='
```

已知目标机已经确认：

```text
CONFIG_KPROBES=y
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODVERSIONS=y
```

必须进一步确认：

```text
CONFIG_KRETPROBES=y
```

如果 `CONFIG_KRETPROBES` 未启用，**不要偷偷退化为不安全的函数入口 free**，进入第 9 节 fallback 评估。

### 4.3 kretprobe 目标

注册两个 probe：

```text
sched_ext_free
scx_cancel_fork
```

必须使用：

```c
.symbol_name = "sched_ext_free"
```

和：

```c
.symbol_name = "scx_cancel_fork"
```

禁止依赖 `/proc/kallsyms` 中的绝对地址。

目标设备已经实测普通 kprobe 可以通过符号名挂到：

```text
scx_pre_fork
```

即：

```text
p:scx_test scx_pre_fork
```

注册成功并持续命中，因此 symbol-based kprobe 路线是可行的。

---

## 5. kretprobe handler 设计

### 5.1 per-instance context

每个 kretprobe instance 使用：

```c
struct scx_hotfix_ctx {
    struct task_struct *task;
};
```

并：

```c
.data_size = sizeof(struct scx_hotfix_ctx);
```

### 5.2 entry handler

ARM64 目标上第一个函数参数为 `x0`。

entry handler：

```c
static int hotfix_entry(struct kretprobe_instance *ri,
                        struct pt_regs *regs)
{
    struct scx_hotfix_ctx *ctx = ri->data;

    ctx->task = (struct task_struct *)regs->regs[0];
    return 0;
}
```

要求：

- 不分配内存；
- 不获取 sleepable lock；
- 不调用 `kfree()`；
- 只保存 task 指针。

如果后续希望支持非 arm64，必须抽象参数读取方式；v1 可以明确只支持 arm64。

### 5.3 return handler

return handler 的逻辑目标：

```c
p = ctx->task;
scx = p->scx;

if (scx is valid and owned by p) {
    atomically clear p->scx;
    kfree(scx);
    update stats;
}
```

推荐伪代码：

```c
static int hotfix_ret(struct kretprobe_instance *ri,
                      struct pt_regs *regs)
{
    struct scx_hotfix_ctx *ctx = ri->data;
    struct task_struct *p = ctx->task;
    struct sched_ext_entity *scx;

    if (!p) {
        stat_bad_task++;
        return 0;
    }

    scx = READ_ONCE(p->scx);
    if (!scx) {
        stat_null++;
        return 0;
    }

    /*
     * Ownership sanity check.
     * Target source initializes:
     *     p->scx->task = p;
     */
    if (READ_ONCE(scx->task) != p) {
        stat_owner_mismatch++;
        pr_warn_ratelimited(...);
        return 0;
    }

    /*
     * Claim exactly once.
     */
    if (cmpxchg(&p->scx, scx, NULL) != scx) {
        stat_raced++;
        return 0;
    }

    kfree(scx);
    stat_freed++;

    return 0;
}
```

### 5.4 为什么需要 ownership check

目标源码在 `scx_pre_fork()` 中明确：

```c
p->scx->task = p;
```

因此：

```c
scx->task == p
```

可以作为非常便宜的 ABI/layout sanity check。

如果 module 是用错误 headers / 错误 branch 构建，`task_struct::scx` offset 不匹配时，禁止直接 free 一个任意地址。

### 5.5 为什么需要 cmpxchg/xchg

模块可能：

- 两条 teardown path 因异常逻辑重复触发；
- 未来官方补丁已经加入 `p->scx = NULL`；
- 与其它 hotfix 共存。

因此必须将：

```text
p->scx != NULL -> p->scx = NULL
```

作为单次 ownership transfer。

目标是：

```text
只有成功把 p->scx 从原 pointer 原子替换为 NULL 的 handler
才拥有 kfree(pointer) 的权利
```

不要使用：

```c
kfree(p->scx);
p->scx = NULL;
```

作为无保护的两步操作。

---

## 6. 两条 destructor 路径

建议不要共用一个匿名计数，分别统计。

### 6.1 正常生命周期

probe：

```text
sched_ext_free
```

return handler：

```text
freed_normal++
```

语义：

```text
task final release
 -> sched_ext_free() 原逻辑
 -> [kretprobe return]
 -> kfree(p->scx)
 -> caller continues __put_task_struct()
```

### 6.2 fork failure

probe：

```text
scx_cancel_fork
```

return handler：

```text
freed_cancel++
```

语义：

```text
fork error
 -> scx_cancel_fork() 原逻辑
 -> [kretprobe return]
 -> kfree(p->scx)
 -> remaining copy_process cleanup
 -> delayed_free_task()
```

目标 MT6989 `copy_process()` 在 `sched_cancel_fork(p)` 后的 cleanup 不再访问 SCX entity，因此这个点符合源代码 destructor 语义。

---

## 7. maxactive / 高 task churn 要求

目标设备实测 task creation 峰值达到：

```text
~57.7 tasks/sec
```

并且双 userspace 环境可能更高。

kretprobe 必须考虑并发 active instances。

不要依赖过小默认值。

建议：

```c
.maxactive = max_t(int, 64, num_possible_cpus() * 8);
```

或固定：

```c
.maxactive = 256;
```

具体由编码智能体根据该 kernel kretprobe 实现确认。

必须暴露/打印：

```text
normal_kretprobe.nmissed
cancel_kretprobe.nmissed
```

Acceptance criteria：

```text
nmissed == 0
```

如果长期压力测试 `nmissed > 0`：

- 提高 maxactive；
- 不得把“漏掉的 probe”当成无害，因为每次 missed 就意味着潜在继续泄漏一个对象。

---

## 8. Module 初始化与退出

### 8.1 init

初始化必须是 transactional：

1. ABI/build sanity checks；
2. 注册 `sched_ext_free` kretprobe；
3. 注册 `scx_cancel_fork` kretprobe；
4. 任一失败：
   - 注销已经注册的 probe；
   - 返回错误；
   - 不允许 half-enabled。

示意：

```c
ret = register_kretprobe(&krp_sched_ext_free);
if (ret)
    return ret;

ret = register_kretprobe(&krp_scx_cancel_fork);
if (ret) {
    unregister_kretprobe(&krp_sched_ext_free);
    return ret;
}
```

成功日志建议：

```text
scx_leak_hotfix: active
scx_leak_hotfix: hooks=sched_ext_free(ret),scx_cancel_fork(ret)
scx_leak_hotfix: scx_size=232
```

### 8.2 exit

开发版允许 `rmmod`，必须：

```c
unregister_kretprobe(&krp_scx_cancel_fork);
unregister_kretprobe(&krp_sched_ext_free);
```

再输出 stats。

生产/post-fs-data 使用场景建议模块常驻，不主动卸载。

卸载模块不会恢复已经泄漏的对象，也意味着之后新 task 会重新开始泄漏。

---

## 9. `CONFIG_KRETPROBES=n` 时的 fallback 规则

### 9.1 禁止方案

以下方案在 v1 中明确禁止：

#### 禁止 A：`free_task()` 函数入口直接 free

目标源码：

```c
void free_task(struct task_struct *tsk)
{
    ...
    trace_android_vh_free_task(tsk);
    ...
    bpf_task_storage_free(tsk);
    free_task_struct(tsk);
}
```

在 `free_task()` 入口将 `p->scx` free 掉，可能导致后续 vendor hook / cleanup 读取已释放对象。

因此禁止。

#### 禁止 B：在 `sched_ext_free()` / `scx_cancel_fork()` 入口 free

原函数本身仍会 dereference `p->scx`，会立即产生 UAF。

#### 禁止 C：硬编码函数 offset

例如：

```text
sched_ext_free+0xNN
```

不能作为发布版方案。

编译优化、LTO、版本变化都会改变 offset。

### 9.2 可评估 fallback：Android vendor hook

目标 `free_task()` 中存在：

```c
trace_android_vh_free_task(tsk);
```

目标源码 `include/trace/hooks/sched.h` 声明：

```c
DECLARE_HOOK(android_vh_free_task,
    TP_PROTO(struct task_struct *p),
    TP_ARGS(p));
```

源码：

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/include/trace/hooks/sched.h`

Android vendor hooks 的设计目的就是允许 vendor modules 扩展核心 kernel。

因此若 `CONFIG_KRETPROBES=n`，编码智能体可以评估：

```c
register_trace_android_vh_free_task(...)
```

但只有在以下条件全部确认后才可启用：

1. 对应 tracepoint registration symbol 在 `Module.symvers` 可用；
2. GPL/KMI 条件满足；
3. 明确 callback ordering；
4. 确认不会在本 callback 之后存在依赖 `p->scx` 的其它回调；
5. 能做到 fail closed。

如果不能证明第 3/4 点，则 **不要自动实现这个 fallback**。

更优做法是要求目标内核开启 KRETPROBES 或直接源码 patch。

---

## 10. ABI / KMI / 构建要求

目标机：

```text
CONFIG_MODVERSIONS=y
```

所以必须尽量使用与运行内核严格匹配的：

- OnePlusOSS source branch/commit；
- `.config`；
- generated headers；
- `Module.symvers`；
- Clang/LLVM toolchain；
- localversion / ABI。

禁止：

- 用“相近 Android 版本”的随机 headers；
- 从其它 SoC 拿 `Module.symvers`；
- 手写 `task_struct`；
- 硬编码 `offsetof(task_struct, scx)`。

### 10.1 module license

kprobe/kretprobe 等接口可能为 GPL export。

必须：

```c
MODULE_LICENSE("GPL");
```

建议：

```c
MODULE_DESCRIPTION("Hotfix for OnePlus/Oplus sched_ext per-task scx memory leak");
MODULE_AUTHOR(...);
MODULE_VERSION("0.1");
```

---

## 11. Compile-time guards

建议至少：

```c
#if !IS_ENABLED(CONFIG_SLIM_SCHED)
#error "This hotfix requires CONFIG_SLIM_SCHED"
#endif

#if !IS_ENABLED(CONFIG_SCHED_CLASS_EXT)
#error "This hotfix requires CONFIG_SCHED_CLASS_EXT"
#endif

#if !IS_ENABLED(CONFIG_KPROBES)
#error "This hotfix requires CONFIG_KPROBES"
#endif
```

kretprobe primary implementation：

```c
#if !IS_ENABLED(CONFIG_KRETPROBES)
#error "Primary hotfix implementation requires CONFIG_KRETPROBES"
#endif
```

如果要支持多个 profile，不要让一个 generic module 在未知 layout 上运行。

---

## 12. MT6989 profile sanity checks

目标 branch 的实机 `sizeof(struct sched_ext_entity)` 已由 kmalloc trace 间接确认：

```text
232 bytes
```

且 slab allocation：

```text
256 bytes
```

MT6989 专用 build 可以考虑：

```c
static_assert(sizeof(struct sched_ext_entity) == 232);
```

但跨平台 build 不应该全局硬编码 232，因为不同 kernel config 可能影响结构大小，例如 `CONFIG_SCHED_CORE` 等。

更通用的策略：

- 编译时使用目标源码自己的 struct；
- 运行时通过 `scx->task == p` 做 ownership sanity；
- build profile 记录 expected source commit/config。

---

## 13. 已存在泄漏对象的处理策略

### 13.1 可以安全处理

模块加载前已经存在、但仍存活的 task：

```text
task alive at module load
 -> later exits
 -> sched_ext_free return hook
 -> p->scx gets freed
```

因此这些对象会被正常收尾。

### 13.2 不允许处理

模块加载前已经退出的 task 对应 orphan `scx` 对象：

- 原 task_struct 已释放；
- 已从 `scx_tasks` list 移除；
- ownership 已丢失。

禁止：

- 扫描 `kmalloc-256`；
- 根据内容猜 `struct sched_ext_entity`；
- 扫描物理内存；
- 对历史对象批量 `kfree()`。

这些对象只能通过重启清空。

因此推荐部署：

```text
reboot
 -> post-fs-data
 -> 尽早 insmod hotfix
 -> 阻止后续大规模泄漏
```

---

## 14. post-fs-data 部署约束

模块设计必须适合早期加载。

示例部署逻辑：

```sh
#!/system/bin/sh

MOD=/data/adb/modules/scx_leak_hotfix/scx_leak_hotfix.ko

if [ -f "$MOD" ]; then
    insmod "$MOD"
fi
```

具体 Magisk/KernelSU/APatch 集成方式不属于 module 核心实现规范。

要求：

- 重复 `insmod` 应明确失败，不造成副作用；
- 模块常驻；
- 不自动 rmmod；
- init failure 必须写入 dmesg。

---

## 15. 可观测性 / stats

至少维护：

```c
atomic64_t freed_normal;
atomic64_t freed_cancel;
atomic64_t skipped_null;
atomic64_t owner_mismatch;
atomic64_t claim_race;
atomic64_t bad_task;
```

建议额外输出：

```text
sched_ext_free kretprobe nmissed
scx_cancel_fork kretprobe nmissed
```

### 15.1 debugfs（推荐但可选）

若 `CONFIG_DEBUG_FS=y`：

```text
/sys/kernel/debug/scx_leak_hotfix/stats
```

建议内容：

```text
version: 0.1
active: 1
sizeof_sched_ext_entity: 232
freed_normal: ...
freed_cancel: ...
freed_total: ...
skipped_null: ...
owner_mismatch: ...
claim_race: ...
normal_nmissed: ...
cancel_nmissed: ...
```

禁止在每次 task free 时 `pr_info()`，否则高 churn 下会刷爆日志。

只允许：

```c
pr_warn_ratelimited()
```

报告异常。

---

## 16. 验证方案

### 16.1 加载前 baseline

```sh
a=$(awk '/^processes / {print $2}' /proc/stat)
s=$(awk '/^kmalloc-256 / {print $2}' /proc/slabinfo)

sleep 60

b=$(awk '/^processes / {print $2}' /proc/stat)
e=$(awk '/^kmalloc-256 / {print $2}' /proc/slabinfo)

echo "new tasks       = $((b-a))"
echo "kmalloc-256 net = $((e-s))"
```

bug kernel 已观察到：

```text
new tasks       = 2344
kmalloc-256 net = 2336
```

### 16.2 加载 hotfix 后

同样测试至少：

- 60 秒；
- 5 分钟；
- 1 小时；
- 实际双 userspace 长时间 workload。

预期：

```text
new tasks       = 大量增长
kmalloc-256 net != 近似 1:1 增长
```

注意 `kmalloc-256` 有其它合法用户，因此不要求精确为 0。

核心 acceptance：

```text
Δkmalloc-256 / Δtasks
```

应从接近：

```text
~1 object/task
```

降到接近正常背景噪声。

### 16.3 module stats 对照

理想：

```text
freed_normal + freed_cancel
```

应与模块加载后结束的相关 task 数同量级。

同时：

```text
normal_nmissed = 0
cancel_nmissed = 0
owner_mismatch = 0
```

### 16.4 kfree tracing 验证

可再次追踪：

```text
kmalloc:
call_site=scx_pre_fork
bytes_req=232
bytes_alloc=256
```

然后确认这些对象在 task teardown 后出现对应 `kfree`。

### 16.5 稳定性

压力测试期间不得出现：

```text
BUG:
Oops:
KASAN:
use-after-free
double free
slab corruption
list corruption
RCU stall
```

必须检查：

```sh
dmesg | tail -n ...
```

---

## 17. 长期效果验证

建议在 reboot + early hotfix load 后持续运行原双 userspace 环境。

每小时记录：

```sh
date
awk '/^processes / {print}' /proc/stat
grep '^kmalloc-256 ' /proc/slabinfo
grep -E '^(Slab|SReclaimable|SUnreclaim|MemFree|MemAvailable):' /proc/meminfo
cat /proc/buddyinfo
```

可选：

```sh
cat /sys/kernel/debug/extfrag/extfrag_index
```

预期：

1. `/proc/stat processes` 继续高速增加；
2. `kmalloc-256 active` 不再长期随累计 task 数线性增加；
3. `SUnreclaim` 不再以相同模式增长；
4. reboot 后高阶 buddy 状态不会再因该 leak 快速恶化；
5. compaction/extfrag 压力显著下降或至少不再被该 leak 持续放大。

---

## 18. 性能要求

hotfix 位于 task teardown 热路径。

return handler 必须接近 O(1)：

```text
read pointer
ownership sanity check
atomic claim
kfree
atomic counter
```

禁止：

- mutex；
- sleep；
- workqueue per task；
- 动态 allocation；
- 全局 hash table；
- stack trace；
- printk per task；
- slab scan。

---

## 19. 安全性规则

编码智能体必须遵守：

### MUST

- exact headers；
- exact source branch；
- symbol-name kretprobe；
- ownership check；
- atomic pointer claim；
- NULL-safe；
- transactional init；
- rate-limited diagnostics；
- fail closed。

### MUST NOT

- hardcoded kernel virtual addresses；
- hardcoded `task_struct` offset；
- hook `kmalloc` globally；
- patch kernel text；
- disable write protection；
- modify page tables；
- inline binary patch；
- scan arbitrary kernel memory；
- reclaim pre-existing orphan objects；
- free before original SCX teardown completes。

---

## 20. 官方源码修复的等价目标

LKM 的行为应尽可能等价于未来源码 patch：

```c
void scx_cancel_fork(struct task_struct *p)
{
    if (scx_enabled())
        scx_ops_disable_task(p);

    percpu_up_read(&scx_fork_rwsem);

    kfree(p->scx);
    p->scx = NULL;
}
```

以及：

```c
void sched_ext_free(struct task_struct *p)
{
    ...

    kfree(p->scx);
    p->scx = NULL;
}
```

注意：以上只是 ownership 目标示意。

正式源码 patch 还应单独处理：

```text
scx_pre_fork() kmalloc failure
```

当前函数为 `void` 且 allocation failure 后仍可能进入后续路径，这是另一个需要内核团队修复的问题，不应由本 LKM 擅自改变 fork 语义。

---

## 21. 跨平台扩展

已在 OnePlusOSS 多个源码树观察到相同模式，至少包括：

```text
Qualcomm:
SM7635
SM8635
SM8650
SM8735
SM8750

MediaTek:
MT6878
MT6897
MT6989
MT6991
```

但 v1 不应宣称一个 `.ko` 可直接跨这些 platform 使用。

每个平台 profile 必须重新确认：

1. `task_struct::scx` 是否为 pointer；
2. `scx_pre_fork()` 是否动态 `kmalloc()`；
3. `sched_ext_free()` 是否缺 `kfree()`；
4. `scx_cancel_fork()` 是否缺 `kfree()`；
5. struct layout；
6. exact config；
7. symbol availability；
8. Module.symvers；
9. toolchain；
10. kretprobe availability。

如果新一代内核已经恢复：

```c
struct sched_ext_entity scx;
```

内嵌形式，则 **严禁加载本 hotfix**。

在该内核上加载针对 pointer layout 的 hotfix 会造成严重内核崩溃。

---

## 22. 推荐项目结构

```text
scx-leak-hotfix/
├── Makefile
├── scx_leak_hotfix.c
├── README.md
├── profiles/
│   └── mt6989_ace5_race.md
├── scripts/
│   ├── preflight.sh
│   ├── stress_test.sh
│   └── collect_stats.sh
└── LICENSE
```

### `preflight.sh`

应检查：

```text
uname -a
/proc/version
/proc/config.gz
scx symbols
module ABI
```

并输出明确 PASS/FAIL。

### `stress_test.sh`

只负责制造可控 task churn + 记录：

```text
/proc/stat processes
/proc/slabinfo kmalloc-256
```

### `collect_stats.sh`

记录：

```text
meminfo
slabinfo
buddyinfo
extfrag_index
module stats
```

---

## 23. 编码智能体交付物

编码智能体最终至少必须给出：

1. `scx_leak_hotfix.c`
2. `Makefile`
3. `README.md`
4. `preflight.sh`
5. `stress_test.sh`
6. 清楚写明需要的 source branch / Module.symvers / toolchain
7. build command
8. `insmod` command
9. `rmmod`（仅开发测试）说明
10. validation procedure
11. 已知风险
12. 不支持 kernel 的拒绝策略

不要只返回一段概念代码。

---

## 24. Definition of Done

仅当以下条件全部满足，才算 v1 完成：

- [ ] exact MT6989 headers 构建成功；
- [ ] `modinfo` 正常；
- [ ] `insmod` 成功；
- [ ] 两个 teardown probe 均成功注册；
- [ ] 5 分钟 task churn 下无 crash/warning；
- [ ] `owner_mismatch == 0`；
- [ ] `nmissed == 0`；
- [ ] task 数大量增长；
- [ ] `kmalloc-256` 不再与 task creation 近似 1:1 增长；
- [ ] module freed counter 持续增加；
- [ ] kfree tracing 能观察到 SCX 对象生命周期闭环；
- [ ] 长时间测试 `SUnreclaim` 不再按原趋势增长；
- [ ] reboot + post-fs-data early load 可稳定工作。

---

## 25. 关键源码参考

### MT6989

仓库：

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989`

分支：

`oneplus/mt6989_v_15.0.2_ace5_race`

#### `scx_pre_fork()` / `scx_cancel_fork()` / `sched_ext_free()`

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/kernel/sched/ext.c`

关键区域：

```text
scx_pre_fork     ≈ L2128
scx_cancel_fork  ≈ L2192
sched_ext_free   ≈ L2199
```

#### `task_struct::scx`

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/include/linux/sched.h`

关键区域：

```text
CONFIG_SLIM_SCHED
ANDROID_KABI_USE(... struct sched_ext_entity *scx)
≈ L1469-L1475
```

#### `struct sched_ext_entity`

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/include/linux/sched/ext.h`

注意源码注释仍写：

```text
"The following is embedded in task_struct"
```

但 vendor `task_struct` 实际已经改成 pointer。

#### task teardown

`https://github.com/OnePlusOSS/android_kernel_oneplus_mt6989/blob/oneplus/mt6989_v_15.0.2_ace5_race/kernel/fork.c`

关键逻辑：

```text
__put_task_struct()
 -> sched_ext_free()
 -> ...
 -> free_task()

copy_process() failure
 -> sched_cancel_fork()
 -> ...
 -> delayed_free_task()
```

---

## 26. 给编码智能体的最终指令摘要

实现一个 **MT6989 专用、fail-closed、arm64 LKM hotfix**。

不要改 scheduler 行为。

不要 hook allocation。

首选两个 kretprobe：

```text
sched_ext_free RETURN
scx_cancel_fork RETURN
```

entry 保存 `struct task_struct *`。

return 时：

```text
validate p
read p->scx
validate scx->task == p
atomically claim p->scx -> NULL
kfree(scx)
increment counter
```

任何 ABI/symbol/probe 不匹配直接拒绝加载。

目标验证结果：

```text
/proc/stat processes
```

继续高速增加，但：

```text
kmalloc-256 active_objs
```

不再随它近似 1:1 线性增长。

这就是本 hotfix 的核心成功判据。
