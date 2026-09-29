//
//  GZZ.m — 古代战争 2.4.1 (com.maobu.jiushizhuunity) 悬浮助手 v1
//  ═══════════════════════════════════════════════════════════════════════
//  引擎: Unity 2019.4.30f1 + IL2CPP (global-metadata v24.2) + xLua 热更(明文)
//  二进制: Frameworks/UnityFramework.framework/UnityFramework (arm64, 90.7MB, 229 个 il2cpp_* 导出)
//  主程序: JiuShiZhuUnityIOS (70KB 壳, 逻辑全在 UnityFramework)
//
//  功能:
//   ① 秒杀  —— 三条并行策略 (各自带命中计数, 真机日志可判定哪条生效)
//       a) 自动跳过战斗: hook BattlePanel::Update → 战斗开始 N 帧后自动调
//          BattlePanel::TiaoGuo(), 客户端瞬间出结果 (最稳, 不依赖数值注入)
//       b) 飞机大战(FeiJi)敌人秒杀: hook FeiJiEnemy::Damage(float)
//       c) 客户端战斗单元血线归零: hook BattleHeroCell::ChangeHp
//   ② 加速  —— hook UnityEngine.Time::set_timeScale 做倍率放大 +
//              主线程 0.5s 定时器持续钉住 (对抗游戏自身重置)
//
//  ⚠️ 该游戏【回合战斗结算为服务端权威】(BattleLog 由服务器下发), 伤害数值
//     注入只对客户端小游戏(飞机大战/探索)有效, 主线回合战斗用「自动跳过」
//     达成等效的快速通关。所有 hook 目标均在真机解析成功后才安装,
//     缺一个不影响其余功能。
//  ⚠️ 仅单机/单人玩法使用。竞技场(JJC)、跨服、组队为联机, 勿开秒杀。
//  ═══════════════════════════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

// ───────────────────────── 日志 ─────────────────────────
static NSString *g_doc = nil;
static NSString *gzz_doc(void) {
    if (!g_doc) {
        NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        g_doc = p.count ? p.firstObject : nil;
    }
    return g_doc;
}
static void L(const char *fmt, ...) {
    char msg[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    NSString *d = gzz_doc();
    if (d) {
        NSString *p = [d stringByAppendingPathComponent:@"gdzz.log"];
        FILE *f = fopen(p.fileSystemRepresentation, "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    }
    NSLog(@"[GZZ] %s", msg);
}

// ───────────────────────── 开关 / 计数 ─────────────────────────
static BOOL  g_killOn   = NO;
static BOOL  g_speedOn  = NO;
static float g_speedMul = 3.0f;
static BOOL  g_forceWin = NO;     // 强制胜利 (默认关, 需真机验证)
static int   g_myCamp   = -1;     // 我方阵营 (运行时读 BattleModel 静态常量)

static volatile int g_nSkip     = 0;   // 自动跳过战斗次数
static volatile int g_nDamage   = 0;   // FeiJiEnemy::Damage 命中
static volatile int g_nChangeHp = 0;   // BattleHeroCell::ChangeHp 命中
static volatile int g_nMapAtk   = 0;   // MapHeroCell::Attack 命中
static volatile int g_tsSets    = 0;   // set_timeScale 拦截

static UIButton *g_ball = nil;
static UIView   *g_panel = nil;
static UILabel  *g_stat = nil;
static UISwitch *g_swKill = nil, *g_swSpeed = nil, *g_swWin = nil;
static UIWindow *g_win = nil;
static UISegmentedControl *g_segSpeed = nil;

// ───────────────────────── Mach-O ─────────────────────────
static uint64_t g_unityBase = 0;
static uint64_t g_textSize  = 0;
static int      g_slide     = 0;

static void gzz_find_base(void) {
    if (g_unityBase) return;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, "UnityFramework")) continue;
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        g_slide = _dyld_get_image_vmaddr_slide(i);
        g_unityBase = (uint64_t)h;
        const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
        const struct mach_header_64 *mh = (const struct mach_header_64 *)h;
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
                if (strcmp(sg->segname, "__TEXT") == 0) { g_textSize = sg->vmsize; break; }
            }
            p += lc->cmdsize;
        }
        L("base: UnityFramework %p slide=0x%x __TEXT size=0x%llx", h, (unsigned)g_slide, g_textSize);
        return;
    }
}
static int gzz_ptr_in_text(uintptr_t a) {
    return (a && a >= g_unityBase && a < g_unityBase + g_textSize) ? 1 : 0;
}

static int gzz_make_rwx(void *addr, size_t len) {
    uintptr_t pg = (uintptr_t)getpagesize();
    uintptr_t s = (uintptr_t)addr & ~(pg - 1);
    uintptr_t e = ((uintptr_t)addr + len + pg - 1) & ~(pg - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)s,
                                  (vm_size_t)(e - s), false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) { L("vm_protect FAIL %p len=%zu kr=%d", addr, len, kr); return 0; }
    return 1;
}

// ───────────────────────── ARM64 inline hook ─────────────────────────
// 16 字节补丁:  ldr x16, #8 ; br x16 ; .quad target
// trampoline :  原 4 条指令 + 同样 16 字节跳回 target+16
static int gzz_is_pcrel(uint32_t ins) {
    uint32_t top = ins >> 26;
    if (top == 0x05 || top == 0x25) return 1;             // b / bl
    uint32_t g6 = (ins >> 24) & 0x3F;
    if (g6 == 0x54) return 1;                             // b.cond
    if (g6 == 0x34 || g6 == 0x35) return 1;               // cbz / cbnz
    if (g6 == 0x36 || g6 == 0x37) return 1;               // tbz / tbnz
    if (g6 == 0x10 || g6 == 0x90) return 1;               // adr / adrp
    if (g6 == 0x18 || g6 == 0x58 || g6 == 0x98) return 1; // ldr literal
    return 0;
}

static int gzz_hook(void *target, void *replacement, void **orig_out, const char *tag) {
    if (!target || !replacement) return 0;
    if (!gzz_make_rwx(target, 16)) return 0;
    uint32_t *src = (uint32_t *)target;
    for (int i = 0; i < 4; i++) {
        if (src[i] == 0xD65F03C0) { L("hook[%s] SKIP: ret@insn%d", tag, i); return 0; }
        if (gzz_is_pcrel(src[i])) { L("hook[%s] SKIP: pc-rel@%d (0x%08x)", tag, i, src[i]); return 0; }
    }
    uint32_t *tr = (uint32_t *)mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                                    MAP_PRIVATE | MAP_ANON, -1, 0);
    if (tr == MAP_FAILED) { L("hook[%s] mmap FAIL", tag); return 0; }
    for (int i = 0; i < 4; i++) tr[i] = src[i];
    tr[4] = 0x58000050;  tr[5] = 0xD61F0200;
    *(uint64_t *)&tr[6] = (uint64_t)target + 16;
    sys_icache_invalidate(tr, 64);

    uint32_t patch[4] = { 0x58000050, 0xD61F0200, 0, 0 };
    *(uint64_t *)&patch[2] = (uint64_t)replacement;
    memcpy(src, patch, 16);
    sys_icache_invalidate(target, 16);
    if (orig_out) *orig_out = (void *)tr;
    L("hook[%s] OK target=%p repl=%p tramp=%p", tag, target, replacement, tr);
    return 1;
}

// ───────────────────────── il2cpp C API (dlsym) ─────────────────────────
typedef void Il2CppDomain, Il2CppImage, Il2CppClass, Il2CppObject, Il2CppFieldInfo;
typedef struct { void *methodPointer; } GzzMethodInfo;

typedef struct {
    Il2CppDomain*      (*domain_get)(void);
    void**             (*domain_get_assemblies)(Il2CppDomain*, size_t*);
    Il2CppImage*       (*assembly_get_image)(void*);
    Il2CppClass*       (*class_from_name)(Il2CppImage*, const char*, const char*);
    GzzMethodInfo*     (*class_get_method_from_name)(Il2CppClass*, const char*, int);
    GzzMethodInfo*     (*class_get_methods)(Il2CppClass*, void**);
    const char*        (*class_get_name)(Il2CppClass*);
    const char*        (*class_get_namespace)(Il2CppClass*);
    const char*        (*method_get_name)(GzzMethodInfo*);
    int                (*method_get_param_count)(GzzMethodInfo*);
    void*              (*method_get_param)(GzzMethodInfo*, unsigned);
    void*              (*method_get_return_type)(GzzMethodInfo*);
    void*              (*method_get_declaring_type)(GzzMethodInfo*);
    int                (*type_get_type)(void*);
    const char*        (*type_get_name)(void*);
    const char*        (*image_get_name_)(void*);
    size_t             (*image_get_class_count)(void*);
    Il2CppClass*       (*image_get_class)(void*, size_t);
    void*              (*thread_attach)(Il2CppDomain*);
    void*              (*thread_current)(void);
    Il2CppObject*      (*runtime_invoke)(GzzMethodInfo*, void*, void**, void**);
    uint32_t           (*array_length)(Il2CppObject*);
    Il2CppClass*       (*object_get_class)(Il2CppObject*);
    Il2CppFieldInfo*   (*class_get_field_from_name)(Il2CppClass*, const char*);
    size_t             (*field_get_offset)(Il2CppFieldInfo*);
    Il2CppObject*      (*type_get_object)(const void*);
    void*              (*class_get_type)(Il2CppClass*);
    void*              (*field_get_type)(Il2CppFieldInfo*);
    int                (*class_instance_size)(Il2CppClass*);
    Il2CppClass*       (*class_get_parent)(Il2CppClass*);
    void               (*field_static_get_value)(Il2CppFieldInfo*, void*);
    void               (*field_static_set_value)(Il2CppFieldInfo*, void*);
    void               (*field_get_value)(Il2CppObject*, Il2CppFieldInfo*, void*);
    void               (*field_set_value)(Il2CppObject*, Il2CppFieldInfo*, void*);
} GzzApi;

static GzzApi A;
static BOOL g_apiReady = NO;

// 手动声明（避免 dlsym 名字错）
static void *GZ(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    if (!p) { char b[128]; snprintf(b, sizeof(b), "_%s", n); p = dlsym(RTLD_DEFAULT, b); }
    return p;
}

static BOOL gzz_api_init(void) {
    if (g_apiReady) return YES;
    if (!g_unityBase) gzz_find_base();
    memset(&A, 0, sizeof(A));
    A.domain_get              = (void*)GZ("il2cpp_domain_get");
    A.domain_get_assemblies   = (void*)GZ("il2cpp_domain_get_assemblies");
    A.assembly_get_image      = (void*)GZ("il2cpp_assembly_get_image");
    A.class_from_name         = (void*)GZ("il2cpp_class_from_name");
    A.class_get_method_from_name = (void*)GZ("il2cpp_class_get_method_from_name");
    A.class_get_methods       = (void*)GZ("il2cpp_class_get_methods");
    A.class_get_name          = (void*)GZ("il2cpp_class_get_name");
    A.class_get_namespace     = (void*)GZ("il2cpp_class_get_namespace");
    A.method_get_name         = (void*)GZ("il2cpp_method_get_name");
    A.method_get_param_count  = (void*)GZ("il2cpp_method_get_param_count");
    A.method_get_param        = (void*)GZ("il2cpp_method_get_param");
    A.method_get_return_type  = (void*)GZ("il2cpp_method_get_return_type");
    A.method_get_declaring_type = (void*)GZ("il2cpp_method_get_declaring_type");
    A.type_get_type           = (void*)GZ("il2cpp_type_get_type");
    A.type_get_name           = (void*)GZ("il2cpp_type_get_name");
    A.image_get_name_         = (void*)GZ("il2cpp_image_get_name");
    A.image_get_class_count   = (void*)GZ("il2cpp_image_get_class_count");
    A.image_get_class         = (void*)GZ("il2cpp_image_get_class");
    A.thread_attach           = (void*)GZ("il2cpp_thread_attach");
    A.thread_current          = (void*)GZ("il2cpp_thread_current");
    A.runtime_invoke          = (void*)GZ("il2cpp_runtime_invoke");
    A.array_length            = (void*)GZ("il2cpp_array_length");
    A.object_get_class        = (void*)GZ("il2cpp_object_get_class");
    A.class_get_field_from_name = (void*)GZ("il2cpp_class_get_field_from_name");
    A.field_get_offset        = (void*)GZ("il2cpp_field_get_offset");
    A.type_get_object         = (void*)GZ("il2cpp_type_get_object");
    A.class_get_type          = (void*)GZ("il2cpp_class_get_type");
    A.field_get_type          = (void*)GZ("il2cpp_field_get_type");
    A.class_instance_size     = (void*)GZ("il2cpp_class_instance_size");
    A.class_get_parent        = (void*)GZ("il2cpp_class_get_parent");
    A.field_static_get_value  = (void*)GZ("il2cpp_field_static_get_value");
    A.field_static_set_value  = (void*)GZ("il2cpp_field_static_set_value");
    A.field_get_value         = (void*)GZ("il2cpp_field_get_value");
    A.field_set_value         = (void*)GZ("il2cpp_field_set_value");
    if (!A.domain_get || !A.domain_get_assemblies || !A.assembly_get_image ||
        !A.class_from_name || !A.class_get_method_from_name ||
        !A.method_get_name || !A.method_get_param_count) {
        L("api: ✗ 必需符号缺失 (domain_get=%p class_from_name=%p)",
          A.domain_get, A.class_from_name);
        return NO;
    }
    g_apiReady = YES;
    L("api ✓ il2cpp C API 就绪 (domain_get=%p)", A.domain_get);
    return YES;
}

// ───────────────────────── 程序集 / 类 / 方法 解析 ─────────────────────────
#define GZZ_MAX_IMG 128
static Il2CppImage *g_img[GZZ_MAX_IMG];
static char         g_imgName[GZZ_MAX_IMG][96];
static int          g_nImg = 0;

// ⚠️ 必须用精确名匹配: "Assembly-CSharp-firstpass" 也包含子串 "Assembly-CSharp",
//    用 strstr 会错拿 firstpass 镜像 (里面没有游戏类)。
static int gzz_load_images(void) {
    if (g_nImg) return g_nImg;
    Il2CppDomain *dom = A.domain_get();
    if (!dom) return 0;
    size_t cnt = 0;
    void **asms = A.domain_get_assemblies(dom, &cnt);
    if (!asms) return 0;
    L("img: 域内程序集 %zu 个", cnt);
    for (size_t i = 0; i < cnt && g_nImg < GZZ_MAX_IMG; i++) {
        Il2CppImage *im = A.assembly_get_image(asms[i]);
        if (!im) continue;
        const char *nm = A.image_get_name_ ? A.image_get_name_(im) : NULL;
        if (!nm) continue;
        if (strcmp(nm, "Assembly-CSharp.dll") && strcmp(nm, "UnityEngine.CoreModule.dll") &&
            strcmp(nm, "mscorlib.dll") && strcmp(nm, "UnityEngine.dll")) continue;
        g_img[g_nImg] = im;
        snprintf(g_imgName[g_nImg], sizeof(g_imgName[0]), "%s", nm);
        L("img[%d] %s", g_nImg, nm);
        g_nImg++;
    }
    if (!g_nImg) L("img: ✗ 未找到需要的程序集");
    return g_nImg;
}

static Il2CppImage *gzz_image_named(const char *suffix) {
    for (int i = 0; i < g_nImg; i++)
        if (strstr(g_imgName[i], suffix)) return g_img[i];
    return NULL;
}

// 按 名称+参数个数 精确找方法 (遍历, 避免同名不同参数歧义)
static GzzMethodInfo *gzz_find_method(Il2CppClass *k, const char *name, int nparams) {
    if (!k || !name) return NULL;
    if (A.class_get_methods && A.method_get_name) {
        void *iter = NULL;
        GzzMethodInfo *mi;
        while ((mi = A.class_get_methods(k, &iter)) != NULL) {
            const char *mn = A.method_get_name(mi);
            int pc = A.method_get_param_count ? A.method_get_param_count(mi) : -1;
            if (mn && strcmp(mn, name) == 0 && pc == nparams) return mi;
        }
    }
    if (A.class_get_method_from_name)
        return A.class_get_method_from_name(k, name, nparams);
    return NULL;
}

static GzzMethodInfo *gzz_find_method_any(Il2CppClass *k, const char *name) {
    if (!k || !name || !A.class_get_methods) return NULL;
    void *iter = NULL;
    GzzMethodInfo *mi;
    while ((mi = A.class_get_methods(k, &iter)) != NULL) {
        const char *mn = A.method_get_name(mi);
        if (mn && strcmp(mn, name) == 0) return mi;
    }
    return NULL;
}

static Il2CppClass *gzz_class(const char *imgSuffix, const char *ns, const char *name) {
    Il2CppImage *im = gzz_image_named(imgSuffix);
    if (!im) return NULL;
    Il2CppClass *k = A.class_from_name(im, ns, name);
    if (!k) k = A.class_from_name(im, "", name);
    return k;
}

// 记录方法签名到扫描文件
static void gzz_sig_line(FILE *f, const char *cls, const char *mname, GzzMethodInfo *mi) {
    if (!mi || !f) return;
    const char *rt = "?";
    if (A.method_get_return_type && A.type_get_name) {
        void *rtp = A.method_get_return_type(mi);
        if (rtp) { const char *s = A.type_get_name(rtp); if (s) rt = s; }
    }
    char pb[512] = {0};
    int pc = A.method_get_param_count ? A.method_get_param_count(mi) : 0;
    for (int i = 0; i < pc && i < 8; i++) {
        const char *pn = "?";
        void *pt = A.method_get_param ? A.method_get_param(mi, i) : NULL;
        if (pt && A.type_get_name) { const char *s = A.type_get_name(pt); if (s) pn = s; }
        strncat(pb, pn, sizeof(pb) - strlen(pb) - 2);
        if (i + 1 < pc) strncat(pb, ", ", sizeof(pb) - strlen(pb) - 2);
    }
    fprintf(f, "%s::%s(%s) -> %s   ptr=%p\n", cls, mname, pb, rt,
            mi->methodPointer);
}

// ───────────────────────── 加速: 直接用 il2cpp 调 UnityEngine.Time.set_timeScale ─────────────────────────
// ⭐ 不 hook, 零 __TEXT 修改 → 无代码签名风险。
//    每 0.25s 调用一次把 timeScale 钉在倍数上, 覆盖游戏自身的重置。
static GzzMethodInfo *mi_setTimeScale = NULL;
static GzzMethodInfo *mi_getTimeScale = NULL;

static void gzz_apply_timescale(void) {
    if (!mi_setTimeScale || !mi_setTimeScale->methodPointer) return;
    if (!g_speedOn) return;
    float want = g_speedMul;
    if (want > 20.0f) want = 20.0f;
    float v = want;
    void *args[1] = { &v };
    A.runtime_invoke(mi_setTimeScale, NULL, args, NULL);
    g_tsSets++;
}
static float gzz_read_timescale(void) {
    if (!mi_getTimeScale || !mi_getTimeScale->methodPointer) return -1.0f;
    void *exc = NULL;
    Il2CppObject *r = A.runtime_invoke(mi_getTimeScale, NULL, NULL, &exc);
    if (!r) return -1.0f;
    // 静态返回的 float 被装箱; 解箱取前 4 字节 (il2cpp 值类型对象头后紧跟数据)
    return *(float *)((char *)r + sizeof(void *) * 2);
}

// ───────────────────────── 秒杀: 运行时类遍历 + runtime_invoke ─────────────────────────
// 思路: 不依赖硬编码字段偏移 —— 用运行时类查找 + 真实业务方法调用.
//   FindObjectsOfType(Type) 由 UnityEngine.Object 提供, 返回场景内该类全部实例.
//   ⚠️ 只能找 "活的 UnityEngine.Object"; 纯数据类 (BattleModel/BattleHero) 找不到.
static GzzMethodInfo *mi_findObjType   = NULL;   // UnityEngine.Object::FindObjectsOfType(Type)
static GzzMethodInfo *mi_fjDamage      = NULL;
static GzzMethodInfo *mi_fjCrash       = NULL;
static GzzMethodInfo *mi_mhcDead       = NULL;
static GzzMethodInfo *mi_bhcDead       = NULL;
static GzzMethodInfo *mi_bhcChangeHp   = NULL;
static GzzMethodInfo *mi_bp_TiaoGuo    = NULL;
static GzzMethodInfo *mi_bm_UpdateResult = NULL;
static int            mi_fjDamage_pt   = -1;     // 形参 il2cpp 类型码
static int            mi_bhcChgHp_pt   = -1;

static Il2CppClass *k_fjEnemy = NULL, *k_mhc = NULL, *k_bhc = NULL, *k_bp = NULL, *k_bm = NULL;

// 运行时解析的字段偏移 (避免硬编码)
static int g_bhcCampOff  = -1;  // BattleHeroCell.meCamp  (int)
static int g_bhcNowHp    = -1;  // BattleHeroCell.nowHp   (long)
static int g_bhcMaxHp    = -1;  // BattleHeroCell.maxHp   (long)
static int g_bhcHp       = -1;  // BattleHeroCell.hp      (long)
static int g_bpTimeScale = -1;  // BattlePanel._timeScale (float)
static int g_bhcInstSize = 0;   // BattleHeroCell 实例大小 (越界写保护)

static const char *gzz_obj_classname(Il2CppObject *o) {
    if (!o || !A.object_get_class || !A.class_get_name) return "?";
    Il2CppClass *k = A.object_get_class(o);
    return k ? A.class_get_name(k) : "?";
}

// 场景内指定类的全部实例
static int gzz_find_objects(Il2CppClass *k, Il2CppObject **out, int max) {
    if (!k || !mi_findObjType || !mi_findObjType->methodPointer) return 0;
    if (!A.type_get_object || !A.class_get_type) return 0;
    Il2CppObject *typeObj = A.type_get_object(A.class_get_type(k));
    if (!typeObj) return 0;
    void *args[1] = { typeObj };
    Il2CppObject *arr = A.runtime_invoke(mi_findObjType, NULL, args, NULL);
    if (!arr) return 0;
    // Il2CppArray 布局: obj(16B: klass+monitor) | bounds(8B) | max_length(4B+4B pad)
    //                    | vector[] @ 偏移 32
    size_t n = 0;
    if (A.array_length) {
        n = (size_t)A.array_length(arr);
    } else {
        n = (size_t)*(uint32_t *)((char *)arr + 24);
    }
    Il2CppObject **elems = (Il2CppObject **)((char *)arr + 32);
    int c = 0;
    for (size_t i = 0; i < n && c < max; i++)
        if (elems[i]) out[c++] = elems[i];
    return c;
}

static int gzz_boost_panel(void);
static void gzz_kill_pass(void);

static volatile int g_lastKillN = 0;
static volatile int g_lastSkipN = 0;
static volatile int g_lastWinF   = 0;

// ① 飞机大战 / 探索类敌人: 喂巨额伤害 (客户端模拟, 确定性生效)
static int gzz_kill_enemies(void) {
    static Il2CppObject *buf[512];
    int total = 0;
    if (k_fjEnemy) {
        int n = gzz_find_objects(k_fjEnemy, buf, 512);
        for (int i = 0; i < n; i++) {
            if (mi_fjDamage && mi_fjDamage->methodPointer) {
                if (mi_fjDamage_pt == 13) { float f = 9.9e8f;      void *a[1] = { &f };
                                            A.runtime_invoke(mi_fjDamage, buf[i], a, NULL); }
                else                      { int32_t v = 999999999; void *a[1] = { &v };
                                            A.runtime_invoke(mi_fjDamage, buf[i], a, NULL); }
                total++;
            } else if (mi_fjCrash && mi_fjCrash->methodPointer) {
                A.runtime_invoke(mi_fjCrash, buf[i], NULL, NULL);
                total++;
            }
        }
        g_nDamage += total;
    }
    if (k_mhc && mi_mhcDead && mi_mhcDead->methodPointer) {
        int n = gzz_find_objects(k_mhc, buf, 512);
        for (int i = 0; i < n; i++) A.runtime_invoke(mi_mhcDead, buf[i], NULL, NULL);
        if (n) g_nMapAtk += n;
    }
    return total;
}

// ② 回合战斗: 找到活着的 BattlePanel, 调 TiaoGuo() 立即结算
//    每个实例只跳一次, 确保任何新开的战斗都被秒跳
static int gzz_autoskip(void) {
    static Il2CppObject *buf[64];
    static Il2CppObject *seen[128];
    static int seenN = 0;
    if (!k_bp || !mi_bp_TiaoGuo || !mi_bp_TiaoGuo->methodPointer) return 0;
    int n = gzz_find_objects(k_bp, buf, 64);
    int did = 0;
    for (int i = 0; i < n; i++) {
        int known = 0;
        for (int j = 0; j < seenN; j++) if (seen[j] == buf[i]) { known = 1; break; }
        if (known) continue;
        if (seenN < 128) seen[seenN++] = buf[i];
        else { for (int j = 0; j < 64; j++) seen[j] = seen[j + 64]; seenN = 64; }
        A.runtime_invoke(mi_bp_TiaoGuo, buf[i], NULL, NULL);
        did++;
        L("kill: 自动跳过战斗 (BattlePanel=%p, 场景内 %d 个)", buf[i], n);
    }
    if (did) g_nSkip += did;
    return did;
}

// ③ 强制胜利 (默认关闭, 真机验证后再开)
//    ⚠️【推测，人工验证】BattleModel::UpdateResult(int) 的形参疑为 winCamp;
//       若如此, 传入我方阵营即可让客户端判定胜利。
//       服务端若二次校验则不生效, 且联机模式有封号风险 → 默认关。
static int gzz_force_win(void) {
    static Il2CppObject *buf[32];
    static Il2CppObject *seen[64];
    static int seenN = 0;
    if (!k_bm || !mi_bm_UpdateResult || !mi_bm_UpdateResult->methodPointer) return 0;
    if (g_myCamp < 0) return 0;
    int n = gzz_find_objects(k_bm, buf, 32);
    int did = 0;
    for (int i = 0; i < n; i++) {
        int known = 0;
        for (int j = 0; j < seenN; j++) if (seen[j] == buf[i]) { known = 1; break; }
        if (known) continue;
        if (seenN < 64) seen[seenN++] = buf[i];
        else { for (int j = 0; j < 32; j++) seen[j] = seen[j + 32]; seenN = 32; }
        int32_t camp = g_myCamp;
        void *a[1] = { &camp };
        A.runtime_invoke(mi_bm_UpdateResult, buf[i], a, NULL);
        did++;
        L("kill: 强制胜利 UpdateResult(camp=%d) on %p", g_myCamp, buf[i]);
    }
    if (did) g_lastWinF += did;
    return did;
}

// ③ 回合战斗单元秒杀: 把敌方 (meCamp != 我方) 的血量直接写 0, 再调 Dead()
//    ⚠️ 偏移全部来自运行时字段解析; 越界/解析失败时整条路径自动禁用。
//       若真机日志显示 meCamp=-1, 请贴 gdzz.log 供校准。
static int gzz_kill_units(void) {
    static Il2CppObject *buf[256];
    if (!k_bhc || !mi_bhcDead || !mi_bhcDead->methodPointer) return 0;
    if (g_myCamp < 0 || g_bhcCampOff < 0) return 0;
    if (g_bhcNowHp < 0 && g_bhcMaxHp < 0 && g_bhcHp < 0) return 0;

    int n = gzz_find_objects(k_bhc, buf, 256);
    int done = 0;
    for (int i = 0; i < n; i++) {
        int camp = *(int *)((char *)buf[i] + g_bhcCampOff);
        if (camp == g_myCamp) continue;      // 不动我方
        if (g_bhcNowHp > 0) *(int64_t *)((char *)buf[i] + g_bhcNowHp) = 0;
        if (g_bhcMaxHp > 0) *(int64_t *)((char *)buf[i] + g_bhcMaxHp) = 0;
        if (g_bhcHp    > 0) *(int64_t *)((char *)buf[i] + g_bhcHp)    = 0;
        A.runtime_invoke(mi_bhcDead, buf[i], NULL, NULL);
        done++;
    }
    if (done) g_nChangeHp += done;
    return done;
}

// 一次性诊断: 打印场景内各类实例的真实字段值 (用于校准, 只跑一次)
static void gzz_probe_once(void) {
    static int done = 0;
    if (done) return;
    static Il2CppObject *buf[64];
    int total = 0;

    if (k_bhc) {
        int n = gzz_find_objects(k_bhc, buf, 64);
        L("probe: BattleHeroCell 实例 %d 个 (g_myCamp=%d meCampOff=%d nowHpOff=%d maxHpOff=%d hpOff=%d)",
          n, g_myCamp, g_bhcCampOff, g_bhcNowHp, g_bhcMaxHp, g_bhcHp);
        for (int i = 0; i < n && i < 8; i++) {
            int camp = g_bhcCampOff > 0 ? *(int *)((char *)buf[i] + g_bhcCampOff) : -99;
            int64_t nowHp = g_bhcNowHp > 0 ? *(int64_t *)((char *)buf[i] + g_bhcNowHp) : -1;
            int64_t maxHp = g_bhcMaxHp > 0 ? *(int64_t *)((char *)buf[i] + g_bhcMaxHp) : -1;
            L("  bhc[%d]=%p class=%s camp=%d nowHp=%lld maxHp=%lld",
              i, buf[i], gzz_obj_classname(buf[i]), camp, (long long)nowHp, (long long)maxHp);
            total++;
        }
    }
    if (k_fjEnemy) {
        int n = gzz_find_objects(k_fjEnemy, buf, 64);
        L("probe: FeiJiEnemy 实例 %d 个 (Damage paramType=%d)", n, mi_fjDamage_pt);
        for (int i = 0; i < n && i < 4; i++)
            L("  fj[%d]=%p class=%s", i, buf[i], gzz_obj_classname(buf[i]));
        total += n;
    }
    if (k_bp) {
        int n = gzz_find_objects(k_bp, buf, 32);
        L("probe: BattlePanel 实例 %d 个 (TiaoGuo=%p _timeScaleOff=%d)",
          n, mi_bp_TiaoGuo ? mi_bp_TiaoGuo->methodPointer : NULL, g_bpTimeScale);
        total += n;
    }
    if (k_mhc) {
        int n = gzz_find_objects(k_mhc, buf, 32);
        L("probe: MapHeroCell 实例 %d 个 (Dead=%p)", n, mi_mhcDead ? mi_mhcDead->methodPointer : NULL);
        total += n;
    }
    if (total > 0) done = 1;
}

static void gzz_kill_pass(void) {
    gzz_probe_once();
    if (!g_killOn) return;
    g_lastKillN = gzz_kill_enemies() + gzz_kill_units();
    g_lastSkipN = gzz_autoskip();
    if (g_forceWin) gzz_force_win();
}

// ───────────────────────── 目标表 ─────────────────────────
typedef struct {
    const char *img;      // 程序集后缀
    const char *ns;
    const char *cls;
    const char *mth;
    int         np;
    const char *tag;
    int         kind;
    int         done;
} gzz_target_t;

// kind:  9=绑 set_timeScale   10=绑 get_timeScale
//       20=绑 FindObjectsOfType 21=绑 FeiJiEnemy::Damage  22=绑 Crash
//       23=绑 MapHeroCell::Dead 24=绑 BattleHeroCell::Dead 25=绑 ChangeHp
//       30=缓存运行时类 + 解析字段偏移   8=仅记录签名
static gzz_target_t g_targets[] = {
  {"UnityEngine.CoreModule", "UnityEngine", "Time", "set_timeScale", 1, "Time.set_timeScale", 9, 0},
  {"UnityEngine.CoreModule", "UnityEngine", "Time", "get_timeScale", 0, "Time.get_timeScale", 10, 0},
  {"UnityEngine.CoreModule", "UnityEngine", "Object", "FindObjectsOfType", 1, "Object.FindObjectsOfType", 20, 0},
  {"Assembly-CSharp", "JiuShiZhu", "FeiJiEnemy",     "Damage",   1, "FeiJiEnemy.Damage",    21, 0},
  {"Assembly-CSharp", "JiuShiZhu", "FeiJiEnemy",     "Crash",    0, "FeiJiEnemy.Crash",     22, 0},
  {"Assembly-CSharp", "JiuShiZhu", "MapHeroCell",    "Dead",     0, "MapHeroCell.Dead",     23, 0},
  {"Assembly-CSharp", "JiuShiZhu", "BattleHeroCell", "Dead",     0, "BattleHeroCell.Dead",  24, 0},
  {"Assembly-CSharp", "JiuShiZhu", "BattleHeroCell", "ChangeHp", 1, "BattleHeroCell.ChangeHp", 25, 0},
  {"Assembly-CSharp", "JiuShiZhu", "@CACHE",         "@CAMP",    0, "cache.classes",        30, 0},
  // 仅记录签名 (用于真机核对)
  {"Assembly-CSharp", "JiuShiZhu", "BattlePanel",    "TiaoGuo",  0, "BattlePanel.TiaoGuo", 26, 0},
  {"Assembly-CSharp", "JiuShiZhu", "BattlePanel",    "RunLogic", 1, "BattlePanel.RunLogic", 8, 0},
  {"Assembly-CSharp", "JiuShiZhu", "FeiJiBattleMap", "UpdateMapX", 1, "FeiJiBattleMap.UpdateMapX", 8, 0},
  {"Assembly-CSharp", "JiuShiZhu", "BattlePanel2",   "ChangeHp", 1, "BattlePanel2.ChangeHp", 8, 0},
  {"Assembly-CSharp", "JiuShiZhu", "UIDataModel",    "GetNowBattleSpeed", 0, "UIDataModel.GetNowBattleSpeed", 8, 0},
  {"Assembly-CSharp", "JiuShiZhu", "BattleModel",    "UpdateResult", 1, "BattleModel.UpdateResult", 27, 0},
  {"Assembly-CSharp", "JiuShiZhu", "BattleModel",    "@CAMP",       0, "BattleModel.camp", 31, 0},
};
#define GZZ_NTGT ((int)(sizeof(g_targets) / sizeof(g_targets[0])))

static int   g_tgtDone = 0;
static FILE *g_scanF   = NULL;

static void gzz_scan_open(void) {
    if (g_scanF) return;
    NSString *d = gzz_doc();
    if (!d) return;
    NSString *p = [d stringByAppendingPathComponent:@"gdzz_scan.txt"];
    g_scanF = fopen(p.fileSystemRepresentation, "a");
    if (g_scanF) fprintf(g_scanF, "\n==== scan %s ====\n", [[NSDate date] description].UTF8String);
}

static int gzz_param_type(GzzMethodInfo *mi, int idx) {
    if (!mi || !A.method_get_param || !A.type_get_type) return -1;
    void *pt = A.method_get_param(mi, (unsigned)idx);
    if (!pt) return -1;
    return A.type_get_type(pt);
}

// 运行时解析关键字段偏移
static int gzz_field_off(Il2CppClass *k, const char *name) {
    if (!k || !name || !A.class_get_field_from_name || !A.field_get_offset) return -1;
    Il2CppFieldInfo *f = A.class_get_field_from_name(k, name);
    if (!f) return -1;
    return (int)A.field_get_offset(f);
}
static void gzz_resolve_fields(void) {
    if (k_bhc) {
        g_bhcCampOff = gzz_field_off(k_bhc, "meCamp");
        g_bhcNowHp   = gzz_field_off(k_bhc, "nowHp");
        g_bhcMaxHp   = gzz_field_off(k_bhc, "maxHp");
        g_bhcHp      = gzz_field_off(k_bhc, "hp");
        if (A.class_instance_size) g_bhcInstSize = (int)A.class_instance_size(k_bhc);
    }
    if (k_bp) g_bpTimeScale = gzz_field_off(k_bp, "_timeScale");
    // 越界保护: 字段偏移必须落在实例内且非负
    int sz = g_bhcInstSize > 0 ? g_bhcInstSize : 2048;
    if (g_bhcCampOff < 0 || g_bhcCampOff + 4  > sz) g_bhcCampOff = -1;
    if (g_bhcNowHp   < 0 || g_bhcNowHp   + 8  > sz) g_bhcNowHp   = -1;
    if (g_bhcMaxHp   < 0 || g_bhcMaxHp   + 8  > sz) g_bhcMaxHp   = -1;
    if (g_bhcHp      < 0 || g_bhcHp      + 8  > sz) g_bhcHp      = -1;
    L("cache: bhc instSize=%d meCamp=%d nowHp=%d maxHp=%d hp=%d | bp._timeScale=%d",
      g_bhcInstSize, g_bhcCampOff, g_bhcNowHp, g_bhcMaxHp, g_bhcHp, g_bpTimeScale);
}

// 每 tick 解析 1 个目标 (主线程分步 → 避免 Assembly 惰性初始化竞态)
static void gzz_resolve_step(void) {
    if (g_tgtDone >= GZZ_NTGT) return;
    gzz_target_t *t = &g_targets[g_tgtDone];
    gzz_scan_open();

    if (t->kind == 31) {         // 读 BattleModel 静态阵营常量
        k_bm = gzz_class("Assembly-CSharp", "JiuShiZhu", "BattleModel");
        int a = -1, b = -1;
        if (k_bm && A.class_get_field_from_name && A.field_static_get_value) {
            Il2CppFieldInfo *fa = A.class_get_field_from_name(k_bm, "CAMP_ATTACK_ROLE");
            Il2CppFieldInfo *fb = A.class_get_field_from_name(k_bm, "CAMP_DEFENCE_ROLE");
            if (fa) A.field_static_get_value(fa, &a);
            if (fb) A.field_static_get_value(fb, &b);
        }
        g_myCamp = (a >= 0) ? a : 1;   // 挑战方视为我方; 读不到时回退 1
        L("cache: BattleModel=%p CAMP_ATTACK_ROLE=%d CAMP_DEFENCE_ROLE=%d → g_myCamp=%d",
          k_bm, a, b, g_myCamp);
        t->done = 1; g_tgtDone++; return;
    }

    if (t->kind == 30) {         // 缓存类 + 字段偏移
        k_fjEnemy = gzz_class("Assembly-CSharp", "JiuShiZhu", "FeiJiEnemy");
        k_mhc     = gzz_class("Assembly-CSharp", "JiuShiZhu", "MapHeroCell");
        k_bhc     = gzz_class("Assembly-CSharp", "JiuShiZhu", "BattleHeroCell");
        k_bp      = gzz_class("Assembly-CSharp", "JiuShiZhu", "BattlePanel");
        L("cache: FeiJiEnemy=%p MapHeroCell=%p BattleHeroCell=%p BattlePanel=%p",
          k_fjEnemy, k_mhc, k_bhc, k_bp);
        gzz_resolve_fields();
        t->done = 1; g_tgtDone++; return;
    }

    Il2CppClass *k = gzz_class(t->img, t->ns, t->cls);
    if (!k) {
        L("tgt[%s] ✗ 类未找到", t->tag);
        if (g_scanF) fprintf(g_scanF, "MISS-CLASS %s\n", t->tag);
        t->done = -1; g_tgtDone++; return;
    }
    GzzMethodInfo *mi = gzz_find_method(k, t->mth, t->np);
    if (!mi) mi = gzz_find_method_any(k, t->mth);
    if (!mi || !mi->methodPointer) {
        L("tgt[%s] ✗ 方法未找到", t->tag);
        if (g_scanF) fprintf(g_scanF, "MISS-METHOD %s\n", t->tag);
        t->done = -1; g_tgtDone++; return;
    }
    if (g_scanF) { gzz_sig_line(g_scanF, t->tag, t->mth, mi); fflush(g_scanF); }

    switch (t->kind) {
        case 9:  mi_setTimeScale = mi; L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 10: mi_getTimeScale = mi; L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 20: mi_findObjType = mi;  L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 21: mi_fjDamage = mi; mi_fjDamage_pt = gzz_param_type(mi, 0);
                 L("tgt[%s] ✓ 绑定 %p paramType=%d", t->tag, mi->methodPointer, mi_fjDamage_pt); break;
        case 22: mi_fjCrash = mi;      L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 23: mi_mhcDead = mi;      L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 24: mi_bhcDead = mi;      L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 25: mi_bhcChangeHp = mi; mi_bhcChgHp_pt = gzz_param_type(mi, 0);
                 L("tgt[%s] ✓ 绑定 %p paramType=%d", t->tag, mi->methodPointer, mi_bhcChgHp_pt); break;
        case 26: mi_bp_TiaoGuo = mi;   L("tgt[%s] ✓ 绑定 %p", t->tag, mi->methodPointer); break;
        case 27: mi_bm_UpdateResult = mi;
                 L("tgt[%s] ✓ 绑定 %p paramType=%d (形参是否为 winCamp 待真机验证)",
                   t->tag, mi->methodPointer, gzz_param_type(mi, 0)); break;
        default: L("tgt[%s] = 签名记录 %p", t->tag, mi->methodPointer); break;
    }
    t->done = 1;
    g_tgtDone++;
    if (g_tgtDone == GZZ_NTGT) L("tgt ✓✓ 全部目标处理完成 (k_bhc=%p campOff=%d)", k_bhc, g_bhcCampOff);
}

// ───────────────────────── 主线程 tick ─────────────────────────
static int  g_tick = 0;
static BOOL g_baseDone = NO;

static NSString *gzz_stat_text(void) {
    return [NSString stringWithFormat:
        @"跳过%ld  敌伤%ld  图亡%ld  单元%ld\n"
        @"变速%ld  目标%ld/%d  敌池%@  基址%@",
        (long)g_nSkip, (long)g_nDamage, (long)g_nMapAtk, (long)g_nChangeHp,
        (long)g_tsSets, (long)g_tgtDone, GZZ_NTGT,
        k_fjEnemy ? @"✓" : @"✗", g_unityBase ? @"✓" : @"✗"];
}

static void gzz_tick(void) {
    g_tick++;
    if (!g_baseDone) { gzz_find_base(); g_baseDone = g_unityBase != 0; }

    if (g_tick > 10 && !g_apiReady && g_unityBase) {
        if (!gzz_api_init()) { if (g_tick % 60 == 0) L("api 未就绪, 重试中 (tick=%d)", g_tick); }
    }
    if (g_apiReady && g_nImg == 0) gzz_load_images();
    if (g_apiReady && g_nImg > 0 && g_tgtDone < GZZ_NTGT) {
        // 每 tick 解析 1 个 (主线程分步, 避免长时间阻塞)
        gzz_resolve_step();
        if (g_tgtDone == GZZ_NTGT) L("tgt ✓✓ 全部目标处理完成");
    }

    // 加速: 每 0.25s 直接 invoke Time.set_timeScale (不改 __TEXT → 无签名风险)
    if (g_speedOn) {
        static int c = 0;
        if ((++c % 15) == 0) { gzz_apply_timescale(); gzz_boost_panel(); }
    }
    // 秒杀: 每 0.25s 跑一轮 (FindObjectsOfType + 真实业务方法)
    if (g_killOn && g_apiReady && g_tgtDone >= GZZ_NTGT) {
        static int k = 0;
        if ((++k % 15) == 0) gzz_kill_pass();
    }
    if (g_stat) g_stat.text = gzz_stat_text();
}

// ───────────────────────── UI: event helper (target 必须非 nil) ─────────────────────────
// ⚠️ 铁律: ObjC addTarget: 的 target 为 nil 时事件静默失效. 必须用真实实例.
@interface GzzHelper : NSObject
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIView   *panel;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UISwitch *swKill;
@property (nonatomic, strong) UISwitch *swSpeed;
@property (nonatomic, strong) UISwitch *swWin;
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) CGPoint panStart;
@end

@implementation GzzHelper
static GzzHelper *g_h = nil;

- (void)onBallTap:(id)s {
    (void)s;
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self.win bringSubviewToFront:self.panel];
    L("ui: panel %s", self.panel.hidden ? "closed" : "opened");
}
- (void)onBallPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.win];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.panStart = self.ball.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.ball.center = CGPointMake(self.panStart.x + t.x, self.panStart.y + t.y);
    }
}
- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.win];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.panStart = self.panel.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.panel.center = CGPointMake(self.panStart.x + t.x, self.panStart.y + t.y);
    }
}
- (void)onClose:(id)s { (void)s; self.panel.hidden = YES; }
- (void)onKill:(UISwitch *)s {
    g_killOn = s.isOn;
    L("ui: kill=%d", (int)g_killOn);
}
- (void)onSpeedSw:(UISwitch *)s {
    g_speedOn = s.isOn;
    L("ui: speed=%d mul=%.1f", (int)g_speedOn, g_speedMul);
    gzz_apply_timescale();
}
- (void)onWin:(UISwitch *)s {
    g_forceWin = s.isOn;
    L("ui: forceWin=%d (默认关; 需真机验证 UpdateResult 形参语义)", (int)g_forceWin);
}
- (void)onSeg:(UISegmentedControl *)s {
    static const float m[] = {1.0f, 2.0f, 3.0f, 5.0f};
    NSInteger i = s.selectedSegmentIndex;
    if (i < 0 || i > 3) i = 0;
    g_speedMul = m[i];
    L("ui: speedMul=%.1f", g_speedMul);
    gzz_apply_timescale();
}
- (void)onReset:(id)s {
    (void)s;
    g_nSkip = g_nDamage = g_nChangeHp = g_nMapAtk = g_tsSets = 0;
    L("ui: counters reset");
}
- (void)onScan:(id)s {
    L("ui: 触发全量类扫描");
    // 遍历 Assembly-CSharp 全部类, 打印战斗相关类的方法签名
    Il2CppImage *im = gzz_image_named("Assembly-CSharp");
    if (!im || !A.image_get_class_count || !A.image_get_class) { L("scan: 无 API"); return; }
    size_t n = A.image_get_class_count(im);
    gzz_scan_open();
    if (g_scanF) fprintf(g_scanF, "---- FULL SCAN image=%s classes=%zu ----\n",
                         A.image_get_name_ ? A.image_get_name_(im) : "?", n);
    int hit = 0;
    for (size_t i = 0; i < n; i++) {
        Il2CppClass *k = A.image_get_class(im, i);
        if (!k) continue;
        const char *cn = A.class_get_name(k);
        const char *ns = A.class_get_namespace ? A.class_get_namespace(k) : "";
        if (!cn) continue;
        if (!strstr(cn, "Battle") && !strstr(cn, "FeiJi") && !strstr(cn, "MapHero") &&
            !strstr(cn, "GameLevel") && !strstr(cn, "Boss") && !strstr(cn, "HeroCell") &&
            !strstr(cn, "Damage") && !strstr(cn, "Hurt") && !strstr(cn, "XueZhan")) continue;
        hit++;
        if (g_scanF) fprintf(g_scanF, "\n[CLASS] %s.%s\n", ns, cn);
        void *iter = NULL; GzzMethodInfo *mi;
        while (A.class_get_methods && (mi = A.class_get_methods(k, &iter)) != NULL) {
            if (g_scanF) {
                const char *rt = "?";
                if (A.method_get_return_type && A.type_get_name) {
                    void *rtp = A.method_get_return_type(mi);
                    if (rtp) { const char *s = A.type_get_name(rtp); if (s) rt = s; }
                }
                char pb[512] = {0};
                int pc = A.method_get_param_count ? A.method_get_param_count(mi) : 0;
                for (int j = 0; j < pc && j < 8; j++) {
                    const char *pn = "?";
                    void *pt = A.method_get_param ? A.method_get_param(mi, j) : NULL;
                    if (pt && A.type_get_name) { const char *s = A.type_get_name(pt); if (s) pn = s; }
                    strncat(pb, pn, sizeof(pb) - strlen(pb) - 2);
                    if (j + 1 < pc) strncat(pb, ", ", sizeof(pb) - strlen(pb) - 2);
                }
                fprintf(g_scanF, "  %s(%s) -> %s  %p\n",
                        A.method_get_name(mi), pb, rt, mi->methodPointer);
            }
        }
    }
    if (g_scanF) { fflush(g_scanF); }
    L("scan: 完成, 命中类 %d 个 → Documents/gdzz_scan.txt", hit);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"扫描完成"
        message:[NSString stringWithFormat:@"命中 %d 个战斗类\n签名已写入 Documents/gdzz_scan.txt", hit]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.win.rootViewController presentViewController:a animated:YES completion:nil];
}

- (void)onBtn:(UIButton *)b {
    if (b.tag == 100) [self onReset:b];
    else              [self onScan:b];
}

// 安装: 把所有 target-action / 手势 的真实 target 绑到自己
- (void)install:(UIWindow *)w panel:(UIView *)pnl ball:(UIButton *)ball
         swKill:(UISwitch *)sk swSpeed:(UISwitch *)ss seg:(UISegmentedControl *)sg
           swWin:(UISwitch *)sw
        closeBtn:(UIButton *)x {
    self.win = w; self.panel = pnl; self.ball = ball;
    self.swKill = sk; self.swSpeed = ss; self.seg = sg; self.swWin = sw;

    [ball addTarget:self action:@selector(onBallTap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(onBallPan:)];
    [ball addGestureRecognizer:bp];

    UIPanGestureRecognizer *pp = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(onPanelPan:)];
    [pnl addGestureRecognizer:pp];

    [x addTarget:self action:@selector(onClose:) forControlEvents:UIControlEventTouchUpInside];
    [sk addTarget:self action:@selector(onKill:) forControlEvents:UIControlEventValueChanged];
    [ss addTarget:self action:@selector(onSpeedSw:) forControlEvents:UIControlEventValueChanged];
    [sg addTarget:self action:@selector(onSeg:) forControlEvents:UIControlEventValueChanged];
    [sw addTarget:self action:@selector(onWin:) forControlEvents:UIControlEventValueChanged];
    L("ui: helper install ok (target=%p)", self);
}
@end

static void gzz_build_ui(void) {
    CGRect sb = [UIScreen mainScreen].bounds;
    UIWindow *w = [[UIWindow alloc] initWithFrame:sb];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    w.rootViewController = vc;
    [w makeKeyAndVisible];
    w.hidden = NO;
    g_win = w;

    GzzHelper *H = [GzzHelper new];
    g_h = H;

    // 悬浮球
    CGFloat bs = 56;
    g_ball = [UIButton buttonWithType:UIButtonTypeCustom];
    g_ball.frame = CGRectMake(sb.size.width - bs - 14, sb.size.height * 0.35, bs, bs);
    g_ball.backgroundColor = [UIColor colorWithRed:0.10 green:0.62 blue:0.98 alpha:0.92];
    g_ball.layer.cornerRadius = bs / 2;
    g_ball.layer.borderWidth = 2;
    g_ball.layer.borderColor = [UIColor whiteColor].CGColor;
    g_ball.layer.shadowColor = [UIColor blackColor].CGColor;
    g_ball.layer.shadowOpacity = 0.45;
    g_ball.layer.shadowRadius = 6;
    g_ball.layer.shadowOffset = CGSizeMake(0, 2);
    [g_ball setTitle:@"战" forState:UIControlStateNormal];
    g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [vc.view addSubview:g_ball];

    // 面板
    CGFloat pw = 268, ph = 348;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(12, 90, pw, ph)];
    g_panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.93];
    g_panel.layer.cornerRadius = 14;
    g_panel.layer.borderWidth = 1;
    g_panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    g_panel.hidden = YES;
    [vc.view addSubview:g_panel];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, pw - 60, 22)];
    t.text = @"古代战争助手 v1";
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:15];
    [g_panel addSubview:t];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(pw - 40, 6, 32, 26);
    [x setTitle:@"✕" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:17];
    [g_panel addSubview:x];

    // 秒杀开关
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(14, 38, 140, 30)];
    l1.text = @"秒杀 / 自动跳过";
    l1.textColor = [UIColor colorWithWhite:0.93 alpha:1];
    l1.font = [UIFont systemFontOfSize:13.5];
    [g_panel addSubview:l1];
    g_swKill = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 66, 38, 51, 31)];
    g_swKill.transform = CGAffineTransformMakeScale(0.86, 0.86);
    [g_panel addSubview:g_swKill];

    // 加速开关
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(14, 72, 140, 30)];
    l2.text = @"全局加速";
    l2.textColor = [UIColor colorWithWhite:0.93 alpha:1];
    l2.font = [UIFont systemFontOfSize:13.5];
    [g_panel addSubview:l2];
    g_swSpeed = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 66, 72, 51, 31)];
    g_swSpeed.transform = CGAffineTransformMakeScale(0.86, 0.86);
    [g_panel addSubview:g_swSpeed];

    // 倍率
    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(14, 108, pw - 28, 16)];
    l3.text = @"加速倍率";
    l3.textColor = [UIColor colorWithWhite:0.66 alpha:1];
    l3.font = [UIFont systemFontOfSize:11.5];
    [g_panel addSubview:l3];
    g_segSpeed = [[UISegmentedControl alloc] initWithItems:@[@"1x", @"2x", @"3x", @"5x"]];
    g_segSpeed.frame = CGRectMake(12, 124, pw - 24, 28);
    g_segSpeed.selectedSegmentIndex = 2;
    [g_panel addSubview:g_segSpeed];

    // 强制胜利 (需真机验证)
    UILabel *l4 = [[UILabel alloc] initWithFrame:CGRectMake(14, 158, 160, 30)];
    l4.text = @"强制胜利 (待验证)";
    l4.textColor = [UIColor colorWithRed:1 green:0.78 blue:0.35 alpha:1];
    l4.font = [UIFont systemFontOfSize:13];
    [g_panel addSubview:l4];
    g_swWin = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 66, 158, 51, 31)];
    g_swWin.transform = CGAffineTransformMakeScale(0.86, 0.86);
    [g_panel addSubview:g_swWin];

    // 状态
    g_stat = [[UILabel alloc] initWithFrame:CGRectMake(12, 194, pw - 24, 76)];
    g_stat.numberOfLines = 0;
    g_stat.textColor = [UIColor colorWithRed:0.55 green:0.92 blue:0.62 alpha:1];
    g_stat.font = [UIFont fontWithName:@"Menlo" size:10.5] ?: [UIFont systemFontOfSize:10.5];
    g_stat.text = @"…";
    [g_panel addSubview:g_stat];

    // 按钮
    NSArray *titles = @[@"重置计数", @"扫描战斗类"];
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12 + i * ((pw - 36) / 2 + 12), 276, (pw - 36) / 2, 34);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        b.backgroundColor = i == 0
            ? [UIColor colorWithRed:0.20 green:0.35 blue:0.60 alpha:1]
            : [UIColor colorWithRed:0.62 green:0.30 blue:0.16 alpha:1];
        b.layer.cornerRadius = 8;
        b.tag = 100 + i;
        [g_panel addSubview:b];
    }

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(12, 322, pw - 24, 18)];
    tip.text = @"联机玩法(竞技场/跨服)勿开秒杀";
    tip.textColor = [UIColor colorWithRed:1 green:0.55 blue:0.35 alpha:1];
    tip.font = [UIFont systemFontOfSize:10];
    [g_panel addSubview:tip];

    // 事件桥: target 必须是非 nil 的真实实例
    for (int i = 0; i < 2; i++) {
        UIButton *b = (UIButton *)[g_panel viewWithTag:100 + i];
        [b addTarget:H action:@selector(onBtn:) forControlEvents:UIControlEventTouchUpInside];
    }
    [H install:w panel:g_panel ball:g_ball
         swKill:g_swKill swSpeed:g_swSpeed seg:g_segSpeed swWin:g_swWin closeBtn:x];
    L("ui: 悬浮球+面板已创建 (%@)", NSStringFromCGRect(g_panel.frame));
}

// ───────────────────────── 入口 ─────────────────────────
// NSTimer 的 target 必须非 nil → 用类对象承载类方法
@interface GzzTickKeeper : NSObject
+ (void)fire;
@end
@implementation GzzTickKeeper
+ (void)fire { gzz_tick(); }
@end

// ⚠️ 只 hook 主线程入口 (UIApplicationDelegate didFinishLaunching), 不做后台线程
//    il2cpp 首调 (Assembly 惰性初始化与主线程竞态 → SIGSEGV, 已有两次教训).
__attribute__((constructor))
static void gzz_ctor(void) {
    L("ctor: GZZ v1 载入 (pid=%d)", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gzz_build_ui();
        gzz_find_base();
        L("ctor: base=%p text=0x%llx → tick 启动", (void*)g_unityBase, g_textSize);
        [NSTimer scheduledTimerWithTimeInterval:0.5 target:[GzzTickKeeper class]
                                       selector:@selector(fire)
                                       userInfo:nil repeats:YES];
    });
}
