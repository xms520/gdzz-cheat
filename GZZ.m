//
//  GZZ.m — 古代战争 2.4.1 (com.maobu.jiushizhuunity) 悬浮助手 v3
//  ═══════════════════════════════════════════════════════════════════════
//  v3 修复 (依据真机 gdzz.log + gdzz_scan.txt 判决)
//
//  ⚠️ 崩溃/卡死根因 (全部为"写错偏移", 已彻底移除该类操作):
//   ① 加速闪退: 日志 `bp._timeScale=0` —— il2cpp_field_get_offset 返回 0,
//      我据此执行 `*(float*)(obj+0)=3.0f`, 砸掉对象头部的 klass 指针 → 必崩。
//      → v3 删除 boost_panel, 只走 UnityEngine.Time.set_timeScale。
//   ② 秒杀卡死: 日志显示 10~12 个 BattleHeroCell 实例被处理。
//      我向 hp(off=32) 写 0 —— 而 hp 的 typeIdx=46373 是 UnityEngine.UI.Image
//      (同型字段都是 icon/imgBar/imgDongLi), 即"血条图片引用", 写 0 → 空引用;
//      maxHp(off=216) 实测恒读 0 (偏移不可信)。
//      → v3 删除全部 BattleHeroCell 字段写入与该路径。
//   ③ 强制胜利: scan 显示 BattleModel.UpdateResult(LitJson.JsonData) 形参是
//      对象而非 int → 传 int 必崩。→ v3 删除该功能。
//   ④ 日志 `%@` 在 vsnprintf 中不受支持 → 变参错位 (旧坑第 3 次复现)。
//      → v3 全部改用 %s + .UTF8String。
//   ⑤ CAMP_ATTACK_ROLE/CAMP_DEFENCE_ROLE 静态读回 0, 而实测 meCamp 为 1/2
//      → v3 不再伪造阵营值, 也不再做阵营相关的血量操作。
//
//  v3 功能 (全部只调用游戏自己的业务方法, 不写任何裸偏移):
//   ① 秒杀 = 自动跳过战斗 (BattlePanel::TiaoGuo) + 飞机大战敌人 (FeiJiEnemy::Damage)
//   ② 加速 = 周期性调用 UnityEngine.Time::set_timeScale
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
#include <unistd.h>

// ───────────────────────── 日志 ─────────────────────────
static NSString *g_doc = nil;
static NSString *gzz_doc(void) {
    if (!g_doc) {
        NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        g_doc = p.count ? p.firstObject : nil;
    }
    return g_doc;
}
// ⚠️ 只用 %s/%d/%ld/%p 等 C 格式; 严禁 %@ (vsnprintf 不支持, 会导致变参错位)
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
static float g_speedMul = 2.0f;

static volatile int g_nSkip   = 0;   // 自动跳过战斗次数
static volatile int g_nDamage = 0;   // FeiJiEnemy::Damage 调用次数
static volatile int g_nTsSet  = 0;   // set_timeScale 调用次数
static volatile int g_nExc    = 0;   // C# 异常次数 (关键诊断)
static volatile int g_nBoost  = 0;   // 战斗倍速施加次数

static UIWindow *g_win  = nil;
static UIButton *g_ball = nil;
static UIView   *g_panel = nil;
static UILabel  *g_stat = nil;
static UISwitch *g_swKill = nil, *g_swSpeed = nil;
static UISegmentedControl *g_segSpeed = nil;

// ───────────────────────── Mach-O (仅用于日志/基址诊断) ─────────────────────────
static uint64_t g_unityBase = 0;
static uint64_t g_textSize  = 0;

static void gzz_find_base(void) {
    if (g_unityBase) return;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, "UnityFramework")) continue;
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        g_unityBase = (uint64_t)h;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)h;
        const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
                if (strcmp(sg->segname, "__TEXT") == 0) { g_textSize = sg->vmsize; break; }
            }
            p += lc->cmdsize;
        }
        L("base: UnityFramework %p __TEXT size=0x%llx", h, g_textSize);
        return;
    }
}

// ───────────────────────── il2cpp C API ─────────────────────────
typedef void Il2CppDomain, Il2CppImage, Il2CppClass, Il2CppObject, Il2CppException;
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
    int                (*type_get_type)(void*);
    const char*        (*type_get_name)(void*);
    const char*        (*image_get_name)(void*);
    size_t             (*image_get_class_count)(void*);
    Il2CppClass*       (*image_get_class)(void*, size_t);
    void*              (*thread_attach)(Il2CppDomain*);
    void*              (*thread_current)(void);
    Il2CppObject*      (*runtime_invoke)(GzzMethodInfo*, void*, void**, Il2CppException**);
    uint32_t           (*array_length)(Il2CppObject*);
    Il2CppObject*      (*type_get_object)(const void*);
    void*              (*class_get_type)(Il2CppClass*);
    Il2CppClass*       (*object_get_class)(Il2CppObject*);
} GzzApi;

static GzzApi A;
static BOOL g_apiReady = NO;

// ───────────────────────── 前向声明 (gzz_find_objects / tick 需要) ─────────────────────────
static GzzMethodInfo *mi_findObjType  = NULL;
static GzzMethodInfo *mi_setTimeScale = NULL;
static GzzMethodInfo *mi_fjDamage     = NULL;
static GzzMethodInfo *mi_fjCrash      = NULL;
static GzzMethodInfo *mi_bpTiaoGuo    = NULL;
static GzzMethodInfo *mi_bp2Ctor      = NULL;
static GzzMethodInfo *mi_uiGetSpd     = NULL;
static GzzMethodInfo *mi_spdBtnClick  = NULL;
static int            mi_fjDamage_pt  = -1;
static int            mi_spdBtn_pt    = -1;
static Il2CppClass   *k_fjEnemy = NULL, *k_bp = NULL, *k_bp2 = NULL, *k_ui = NULL, *k_spd = NULL;

// ⭐ 核心决策 (v3.1): 回合战斗由客户端按服务器下发的 BattleLog 播放。
//    「跳过(TiaoGuo)」= 放弃本场 → 判负 (真机日志已证实, 累计 11 次全是失败)。
//    能"赢着秒完"的做法 = 把【播放速度】拉到极限, 战斗几秒播完 → 正常结算我方胜。
static BOOL g_battleSpeedSet = NO;
static BOOL g_useTiaoGuo     = NO;   // 是否使用 TiaoGuo (默认关: 会判负)
static int  g_speedIdx       = 3;    // 战斗倍速档位
static int  g_maxSpeedIdx    = 0;    // 由 GetNowBattleSpeed 探针发现的最大档位

static void gzz_probe_speed(void);
static void gzz_set_battle_speed(int idx);

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
    A.type_get_type           = (void*)GZ("il2cpp_type_get_type");
    A.type_get_name           = (void*)GZ("il2cpp_type_get_name");
    A.image_get_name          = (void*)GZ("il2cpp_image_get_name");
    A.image_get_class_count   = (void*)GZ("il2cpp_image_get_class_count");
    A.image_get_class         = (void*)GZ("il2cpp_image_get_class");
    A.thread_attach           = (void*)GZ("il2cpp_thread_attach");
    A.thread_current          = (void*)GZ("il2cpp_thread_current");
    A.runtime_invoke          = (void*)GZ("il2cpp_runtime_invoke");
    A.array_length            = (void*)GZ("il2cpp_array_length");
    A.type_get_object         = (void*)GZ("il2cpp_type_get_object");
    A.class_get_type          = (void*)GZ("il2cpp_class_get_type");
    A.object_get_class        = (void*)GZ("il2cpp_object_get_class");
    if (!A.domain_get || !A.domain_get_assemblies || !A.assembly_get_image ||
        !A.class_from_name || !A.class_get_methods || !A.method_get_name ||
        !A.method_get_param_count || !A.runtime_invoke) {
        L("api: 必需符号缺失 (domain=%p invoke=%p)", A.domain_get, A.runtime_invoke);
        return NO;
    }
    if (A.thread_current && A.thread_attach && !A.thread_current()) {
        A.thread_attach(A.domain_get());
        L("api: 已 attach 主线程");
    }
    g_apiReady = YES;
    L("api: il2cpp C API 就绪 (domain=%p invoke=%p)", A.domain_get, A.runtime_invoke);
    return YES;
}

// ───────────────────────── 程序集 / 类 / 方法 ─────────────────────────
#define GZZ_MAX_IMG 16
static Il2CppImage *g_img[GZZ_MAX_IMG];
static char         g_imgName[GZZ_MAX_IMG][96];
static int          g_nImg = 0;

// ⚠️ 必须精确比对: "Assembly-CSharp-firstpass.dll" 含子串 "Assembly-CSharp"
static int gzz_load_images(void) {
    if (g_nImg) return g_nImg;
    Il2CppDomain *dom = A.domain_get();
    if (!dom) return 0;
    size_t cnt = 0;
    void **asms = A.domain_get_assemblies(dom, &cnt);
    if (!asms) return 0;
    for (size_t i = 0; i < cnt && g_nImg < GZZ_MAX_IMG; i++) {
        Il2CppImage *im = A.assembly_get_image(asms[i]);
        if (!im) continue;
        const char *nm = A.image_get_name ? A.image_get_name(im) : NULL;
        if (!nm) continue;
        if (strcmp(nm, "Assembly-CSharp.dll") && strcmp(nm, "UnityEngine.CoreModule.dll"))
            continue;
        g_img[g_nImg] = im;
        snprintf(g_imgName[g_nImg], sizeof(g_imgName[0]), "%s", nm);
        L("img[%d] %s", g_nImg, nm);
        g_nImg++;
    }
    return g_nImg;
}

static Il2CppImage *gzz_image_named(const char *suffix) {
    for (int i = 0; i < g_nImg; i++)
        if (strstr(g_imgName[i], suffix)) return g_img[i];
    return NULL;
}

// 遍历法精确匹配 (名称 + 参数个数), 避免同名重载拿错
static GzzMethodInfo *gzz_find_method(Il2CppClass *k, const char *name, int nparams) {
    if (!k || !name || !A.class_get_methods) return NULL;
    void *iter = NULL;
    GzzMethodInfo *mi;
    while ((mi = A.class_get_methods(k, &iter)) != NULL) {
        const char *mn = A.method_get_name(mi);
        int pc = A.method_get_param_count ? A.method_get_param_count(mi) : -1;
        if (mn && strcmp(mn, name) == 0 && pc == nparams) return mi;
    }
    if (A.class_get_method_from_name) return A.class_get_method_from_name(k, name, nparams);
    return NULL;
}

static Il2CppClass *gzz_class(const char *imgSuffix, const char *ns, const char *name) {
    Il2CppImage *im = gzz_image_named(imgSuffix);
    if (!im) return NULL;
    Il2CppClass *k = A.class_from_name(im, ns, name);
    if (!k) k = A.class_from_name(im, "", name);
    return k;
}

// 统一 invoke 包装: 检查 C# 异常, 避免异常对象被静默丢弃导致的状态错乱
static Il2CppObject *gzz_invoke(GzzMethodInfo *mi, void *self, void **args, const char *tag) {
    if (!mi || !mi->methodPointer || !A.runtime_invoke) return NULL;
    Il2CppException *exc = NULL;
    Il2CppObject *r = A.runtime_invoke(mi, self, args, &exc);
    if (exc) {
        g_nExc++;
        if (g_nExc <= 5) L("invoke[%s]: ⚠️ C# 异常 (第 %d 次)", tag, g_nExc);
        return NULL;
    }
    return r;
}

// GZZ_SEEN_MAX / 去重表 (gzz_autoskip 与 gzz_boost_battle 共用)
#define GZZ_SEEN_MAX 32
static Il2CppObject *g_seen[GZZ_SEEN_MAX];
static int            g_seenN = 0;

// 场景内指定类的全部实例 (FindObjectsOfType(Type)); 元素起始偏移 32
static int gzz_find_objects(Il2CppClass *k, Il2CppObject **out, int max) {
    if (!k || !A.type_get_object || !A.class_get_type) return 0;
    Il2CppObject *typeObj = A.type_get_object(A.class_get_type(k));
    if (!typeObj) return 0;
    void *args[1] = { typeObj };
    Il2CppObject *arr = gzz_invoke(mi_findObjType, NULL, args, "FindObjectsOfType");
    if (!arr) return 0;
    // Il2CppArray: obj(16B) | bounds(8B) | max_length(4B+4B pad) | vector[] @32
    size_t n = A.array_length ? (size_t)A.array_length(arr)
                              : (size_t)*(uint32_t *)((char *)arr + 24);
    Il2CppObject **elems = (Il2CppObject **)((char *)arr + 32);
    int c = 0;
    for (size_t i = 0; i < n && c < max; i++)
        if (elems[i]) out[c++] = elems[i];
    return c;
}

// ───────────────────────── 目标解析 ─────────────────────────
static int g_tgtDone = 0;
#define GZZ_NTGT 11

static void gzz_resolve_step(void) {
    if (g_tgtDone >= GZZ_NTGT) return;
    int step = g_tgtDone++;
    switch (step) {
        case 0: {
            k_fjEnemy = gzz_class("Assembly-CSharp", "JiuShiZhu", "FeiJiEnemy");
            k_bp      = gzz_class("Assembly-CSharp", "JiuShiZhu", "BattlePanel");
            L("cache: FeiJiEnemy=%p BattlePanel=%p", k_fjEnemy, k_bp);
            break;
        }
        case 1: {
            Il2CppClass *k = gzz_class("UnityEngine.CoreModule", "UnityEngine", "Object");
            mi_findObjType = k ? gzz_find_method(k, "FindObjectsOfType", 1) : NULL;
            L("tgt: FindObjectsOfType=%p", mi_findObjType ? mi_findObjType->methodPointer : NULL);
            break;
        }
        case 2: {
            Il2CppClass *k = gzz_class("UnityEngine.CoreModule", "UnityEngine", "Time");
            mi_setTimeScale = k ? gzz_find_method(k, "set_timeScale", 1) : NULL;
            L("tgt: Time.set_timeScale=%p", mi_setTimeScale ? mi_setTimeScale->methodPointer : NULL);
            break;
        }
        case 3: {
            mi_fjDamage = k_fjEnemy ? gzz_find_method(k_fjEnemy, "Damage", 1) : NULL;
            if (mi_fjDamage && A.method_get_param && A.type_get_type) {
                void *pt = A.method_get_param(mi_fjDamage, 0);
                if (pt) mi_fjDamage_pt = A.type_get_type(pt);
            }
            L("tgt: FeiJiEnemy.Damage=%p paramType=%d",
              mi_fjDamage ? mi_fjDamage->methodPointer : NULL, mi_fjDamage_pt);
            break;
        }
        case 4: {
            mi_fjCrash = k_fjEnemy ? gzz_find_method(k_fjEnemy, "Crash", 0) : NULL;
            L("tgt: FeiJiEnemy.Crash=%p", mi_fjCrash ? mi_fjCrash->methodPointer : NULL);
            break;
        }
        case 5: {
            mi_bpTiaoGuo = k_bp ? gzz_find_method(k_bp, "TiaoGuo", 0) : NULL;
            L("tgt: BattlePanel.TiaoGuo=%p (⚠️ 点了=判负, 默认不再调用)",
              mi_bpTiaoGuo ? mi_bpTiaoGuo->methodPointer : NULL);
            break;
        }
        case 6: {
            k_bp2 = gzz_class("Assembly-CSharp", "JiuShiZhu", "BattlePanel2");
            mi_bp2Ctor = k_bp2 ? gzz_find_method(k_bp2, "Create", 1) : NULL;
            L("tgt: BattlePanel2=%p Create=%p", k_bp2,
              mi_bp2Ctor ? mi_bp2Ctor->methodPointer : NULL);
            break;
        }
        case 7: {
            k_ui = gzz_class("Assembly-CSharp", "JiuShiZhu", "UIDataModel");
            mi_uiGetSpd = k_ui ? gzz_find_method(k_ui, "GetNowBattleSpeed", 0) : NULL;
            L("tgt: UIDataModel=%p GetNowBattleSpeed=%p", k_ui,
              mi_uiGetSpd ? mi_uiGetSpd->methodPointer : NULL);
            break;
        }
        case 8: {
            k_spd = gzz_class("Assembly-CSharp", "JiuShiZhu", "BattleSpeedComponent");
            if (k_spd) {
                // BtnClick 有重载, 遍历所有同名方法打印参数个数供真机核对
                void *iter = NULL; GzzMethodInfo *mi;
                while (A.class_get_methods && (mi = A.class_get_methods(k_spd, &iter)) != NULL) {
                    const char *mn = A.method_get_name(mi);
                    if (!mn) continue;
                    if (!strcmp(mn, "BtnClick")) {
                        int pc = A.method_get_param_count ? A.method_get_param_count(mi) : -1;
                        L("tgt: BattleSpeedComponent.BtnClick/%d = %p", pc, mi->methodPointer);
                        if (mi_spdBtnClick == NULL) {
                            mi_spdBtnClick = mi;
                            mi_spdBtn_pt = -1;
                            if (pc == 1 && A.method_get_param && A.type_get_type) {
                                void *pt = A.method_get_param(mi, 0);
                                if (pt) mi_spdBtn_pt = A.type_get_type(pt);
                            }
                        }
                    }
                }
            }
            L("tgt: BattleSpeedComponent=%p (BtnClick=%p paramType=%d)",
              k_spd, mi_spdBtnClick ? mi_spdBtnClick->methodPointer : NULL, mi_spdBtn_pt);
            break;
        }
        case 9: {
            L("tgt: 解析完成 (FeiJi=%d Damage=%d BP2=%d UISpd=%d SpdBtn=%d)",
              k_fjEnemy != NULL, mi_fjDamage != NULL, k_bp2 != NULL,
              mi_uiGetSpd != NULL, mi_spdBtnClick != NULL);
            break;
        }
        case 10: {
            gzz_probe_speed();
            break;
        }
    }
}

// ───────────────────────── 加速: 只走 UnityEngine.Time.set_timeScale ─────────────────────────
static void gzz_apply_timescale(void) {
    if (!mi_setTimeScale) return;
    float v = g_speedMul > 20.0f ? 20.0f : g_speedMul;
    void *args[1] = { &v };
    gzz_invoke(mi_setTimeScale, NULL, args, "Time.set_timeScale");
    g_nTsSet++;
}

// ───────────────────────── 秒杀: 只调游戏自己的业务方法 ─────────────────────────
// ① 飞机大战 / 探索小游戏敌人: FeiJiEnemy::Damage(int) 喂大数 (客户端模拟, 安全)
static int gzz_kill_enemies(void) {
    static Il2CppObject *buf[256];
    int done = 0;
    if (k_fjEnemy && mi_fjDamage) {
        int n = gzz_find_objects(k_fjEnemy, buf, 256);
        for (int i = 0; i < n; i++) {
            if (mi_fjDamage_pt == 13) { float f = 9.9e8f;     void *a[1] = { &f };
                                        gzz_invoke(mi_fjDamage, buf[i], a, "FeiJiEnemy.Damage(f)"); }
            else                      { int32_t v = 999999999; void *a[1] = { &v };
                                        gzz_invoke(mi_fjDamage, buf[i], a, "FeiJiEnemy.Damage(i)"); }
            done++;
        }
        g_nDamage += done;
    } else if (k_fjEnemy && mi_fjCrash) {
        int n = gzz_find_objects(k_fjEnemy, buf, 256);
        for (int i = 0; i < n; i++) { gzz_invoke(mi_fjCrash, buf[i], NULL, "FeiJiEnemy.Crash"); done++; }
    }
    return done;
}

// ② 回合战斗「秒完」—— 设置游戏自带的战斗倍速, 把 BattleLog 播放拉到极限。
//    战斗会以极高速度播完, 玩家看不到过程 → 正常结算为我方胜。
//    ⚠️ 不调用 TiaoGuo(): 那是"跳过=放弃本场", 直接判负 (真机日志已证实)。
static void gzz_set_battle_speed(int idx) {
    // 方式 A: 直接调用游戏的倍速组件按钮 (走游戏自己的逻辑, 最安全)
    if (mi_spdBtnClick && k_spd) {
        static Il2CppObject *buf[8];
        int n = gzz_find_objects(k_spd, buf, 8);
        for (int i = 0; i < n; i++) {
            if (mi_spdBtn_pt == 9) {          // bool
                bool b = true; void *a[1] = { &b };
                gzz_invoke(mi_spdBtnClick, buf[i], a, "BattleSpeedComponent.BtnClick(bool)");
            } else if (mi_spdBtn_pt == 8) {   // int
                int32_t v = idx; void *a[1] = { &v };
                gzz_invoke(mi_spdBtnClick, buf[i], a, "BattleSpeedComponent.BtnClick(int)");
            } else {                           // 对象参数 (UI 事件) → 传 NULL 不可靠, 跳过
                return;
            }
        }
        if (n) return;
    }
    // 方式 B: 反复调用 GetNowBattleSpeed() 强制刷新显示 (部分实现会顺带更新内部倍速)
    if (mi_uiGetSpd) gzz_invoke(mi_uiGetSpd, NULL, NULL, "UIDataModel.GetNowBattleSpeed");
}

// 探针: 读取游戏当前战斗倍速档位 (用于校准)
static void gzz_probe_speed(void) {
    static int logged = 0;
    if (logged || !mi_uiGetSpd) return;
    Il2CppObject *r = gzz_invoke(mi_uiGetSpd, NULL, NULL, "GetNowBattleSpeed");
    if (r) {
        int32_t v = *(int32_t *)((char *)r + sizeof(void *) * 2);
        g_maxSpeedIdx = v;
        L("probe: UIDataModel.GetNowBattleSpeed() = %d (最大档位)", v);
        logged = 1;
    }
}

static int gzz_autoskip(void) {
    // v3.1: 默认不再自动跳过 (TiaoGuo = 判负)。
    // 仅在用户显式打开开关时才调用, 便于对比两种行为。
    if (!g_useTiaoGuo) return 0;
    static Il2CppObject *buf[32];
    if (!k_bp || !mi_bpTiaoGuo) return 0;
    int n = gzz_find_objects(k_bp, buf, 32);
    if (n == 0) { g_seenN = 0; return 0; }
    int did = 0;
    for (int i = 0; i < n; i++) {
        int known = 0;
        for (int j = 0; j < g_seenN; j++) if (g_seen[j] == buf[i]) { known = 1; break; }
        if (known) continue;
        if (g_seenN < GZZ_SEEN_MAX) g_seen[g_seenN++] = buf[i];
        gzz_invoke(mi_bpTiaoGuo, buf[i], NULL, "BattlePanel.TiaoGuo");
        did++;
        L("kill: ⚠️ 调用了 TiaoGuo (跳过=判负) BattlePanel=%p", buf[i]);
    }
    g_nSkip += did;
    return did;
}

// 战斗实例出现 → 立刻把播放速度拉满
static void gzz_boost_battle(void) {
    if (k_bp2 || k_bp) {
        Il2CppObject *dummy[4];
        int n = 0;
        if (k_bp)  n += gzz_find_objects(k_bp,  dummy, 4);
        if (k_bp2) n += gzz_find_objects(k_bp2, dummy, 4);
        if (n > 0) {
            gzz_set_battle_speed(g_speedIdx); g_nBoost++;
            if (!g_battleSpeedSet) {
                g_battleSpeedSet = YES;
                L("kill: 战斗中 → 已施加极限倍速 (档位 %d)", g_speedIdx);
            }
        } else if (g_battleSpeedSet) {
            g_battleSpeedSet = NO;
            g_seenN = 0;
            L("kill: 战斗结束 → 复位倍速标记");
        }
    }
}

static void gzz_kill_pass(void) {
    if (!g_killOn) return;
    gzz_kill_enemies();      // 飞机大战/探索小游戏敌人
    gzz_boost_battle();      // 回合战斗: 极限加速播放
    gzz_autoskip();          // 仅当 g_useTiaoGuo 打开 (默认关)
}

// ───────────────────────── 一次性探针 (诊断, 不修改任何内存) ─────────────────────────
static void gzz_probe(void) {
    static int logged = 0;
    static Il2CppObject *buf[64];
    if (logged) return;
    if (k_fjEnemy) {
        int n = gzz_find_objects(k_fjEnemy, buf, 64);
        if (n) {
            L("probe: FeiJiEnemy %d 个 (Damage paramType=%d)", n, mi_fjDamage_pt);
            logged = 1;
        }
    }
    if (!logged && k_bp) {
        int n = gzz_find_objects(k_bp, buf, 32);
        if (n) { L("probe: BattlePanel %d 个 (TiaoGuo=%p)", n,
                   mi_bpTiaoGuo ? mi_bpTiaoGuo->methodPointer : NULL); logged = 1; }
    }
}

// ───────────────────────── 主线程 tick ─────────────────────────
static int   g_tick = 0;
static BOOL  g_baseDone = NO;
static NSString *gzz_stat_text(void) {
    return [NSString stringWithFormat:
        @"战斗加速%ld  敌伤%ld  全局%ld  异常%ld\n"
        @"倍速档%ld  目标%ld/%d  敌池%@",
        (long)g_nBoost, (long)g_nDamage, (long)g_nTsSet, (long)g_nExc,
        (long)g_maxSpeedIdx, (long)g_tgtDone, GZZ_NTGT,
        k_fjEnemy ? @"OK" : @"--"];
}

static void gzz_tick(void) {
    g_tick++;
    if (!g_baseDone) { gzz_find_base(); g_baseDone = g_unityBase != 0; }
    if (g_tick > 6 && !g_apiReady && g_unityBase) gzz_api_init();
    if (g_apiReady && g_nImg == 0) gzz_load_images();
    if (g_apiReady && g_nImg > 0 && g_tgtDone < GZZ_NTGT) {
        gzz_resolve_step();                 // 每 tick 1 步, 主线程分步
    }
    if (g_apiReady && g_tgtDone >= GZZ_NTGT) {
        static int c = 0;
        if ((++c % 10) == 0) {              // 0.5s 一轮
            if (g_killOn)  gzz_kill_pass();
            if (g_speedOn) gzz_apply_timescale();
            gzz_probe();
        }
    }
    if (g_stat) g_stat.text = gzz_stat_text();
}

// ───────────────────────── 可穿透 overlay ─────────────────────────
// ⚠️ 不能用「全屏 window + rootViewController」承载 UI: vc.view 铺满且可交互,
//    hitTest 永远命中它 → 游戏触摸全被吞 (只能点悬浮球)。
// 做法: 重写 hitTest, 空白处返回 nil 让事件透传到下层游戏窗口;
//       且绝不 makeKeyAndVisible (抢 key window 会破坏游戏输入链路)。
@interface GzzOverlayWin : UIWindow
@end
@implementation GzzOverlayWin
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (!v) return nil;
    if (v == self) return nil;
    if (self.rootViewController && v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface GzzOverlayVC : UIViewController
@end
@implementation GzzOverlayVC
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}
@end

// ───────────────────────── UI 事件 (target 必须非 nil) ─────────────────────────
@interface GzzHelper : NSObject
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIView   *panel;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, assign) CGPoint  panStart;
@property (nonatomic, assign) BOOL     shown;
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
    if (g.state == UIGestureRecognizerStateBegan) self.panStart = self.ball.center;
    else if (g.state == UIGestureRecognizerStateChanged)
        self.ball.center = CGPointMake(self.panStart.x + t.x, self.panStart.y + t.y);
}
- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.win];
    if (g.state == UIGestureRecognizerStateBegan) self.panStart = self.panel.center;
    else if (g.state == UIGestureRecognizerStateChanged)
        self.panel.center = CGPointMake(self.panStart.x + t.x, self.panStart.y + t.y);
}
- (void)onClose:(id)s { (void)s; self.panel.hidden = YES; }
- (void)onKill:(UISwitch *)s  { g_killOn  = s.isOn; L("ui: kill=%d",  (int)g_killOn); }
- (void)onSpeedSw:(UISwitch *)s {
    g_speedOn = s.isOn;
    L("ui: speed=%d mul=%.1f", (int)g_speedOn, g_speedMul);
    if (g_speedOn && mi_setTimeScale) gzz_apply_timescale();
    else if (!g_speedOn && mi_setTimeScale) {   // 关闭时还原 1.0
        float v = 1.0f; void *a[1] = { &v };
        gzz_invoke(mi_setTimeScale, NULL, a, "restore_timeScale");
    }
}
- (void)onSeg:(UISegmentedControl *)s {
    static const float m[] = {1.0f, 2.0f, 3.0f, 5.0f};
    NSInteger i = s.selectedSegmentIndex;
    if (i < 0 || i > 3) i = 0;
    g_speedMul = m[i];
    L("ui: speedMul=%.1f", g_speedMul);
    if (g_speedOn && mi_setTimeScale) gzz_apply_timescale();
}
- (void)onReset:(id)s {
    (void)s;
    g_nSkip = g_nDamage = g_nTsSet = g_nExc = 0;
    L("ui: counters reset");
}
- (void)onScan:(id)s {
    Il2CppImage *im = gzz_image_named("Assembly-CSharp");
    if (!im || !A.image_get_class_count || !A.image_get_class) { L("scan: 无 API"); return; }
    size_t n = A.image_get_class_count(im);
    NSString *d = gzz_doc();
    FILE *f = d ? fopen([[d stringByAppendingPathComponent:@"gdzz_scan.txt"] fileSystemRepresentation], "a") : NULL;
    if (!f) { L("scan: 打不开文件"); return; }
    fprintf(f, "\n==== scan %s ====\n", [[NSDate date] description].UTF8String);
    int hit = 0;
    for (size_t i = 0; i < n; i++) {
        Il2CppClass *k = A.image_get_class(im, i);
        if (!k) continue;
        const char *cn = A.class_get_name(k);
        const char *ns = A.class_get_namespace ? A.class_get_namespace(k) : "";
        if (!cn) continue;
        if (!strstr(cn, "Battle") && !strstr(cn, "FeiJi") && !strstr(cn, "MapHero") &&
            !strstr(cn, "GameLevel") && !strstr(cn, "Boss") && !strstr(cn, "HeroCell"))
            continue;
        hit++;
        fprintf(f, "\n[CLASS] %s.%s\n", ns, cn);
        void *iter = NULL; GzzMethodInfo *mi;
        while (A.class_get_methods && (mi = A.class_get_methods(k, &iter)) != NULL) {
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
            fprintf(f, "  %s(%s) -> %s  %p\n", A.method_get_name(mi), pb, rt, mi->methodPointer);
        }
    }
    fclose(f);
    L("scan: 完成, 命中类 %d 个 → Documents/gdzz_scan.txt", hit);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"扫描完成"
        message:[NSString stringWithFormat:@"命中 %d 个战斗类\n签名已写入 Documents/gdzz_scan.txt", hit]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentAlert:a];
}
- (void)presentAlert:(UIAlertController *)a {
    UIViewController *vc = self.win.rootViewController;
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow && w.rootViewController) { vc = w.rootViewController; break; }
    if (!vc) return;
    if (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:a animated:YES completion:nil];
}
- (void)onBtn:(UIButton *)b { if (b.tag == 100) [self onReset:b]; else [self onScan:b]; }

- (void)install:(UIWindow *)w panel:(UIView *)pnl ball:(UIButton *)ball
         swKill:(UISwitch *)sk swSpeed:(UISwitch *)ss seg:(UISegmentedControl *)sg
        closeBtn:(UIButton *)x {
    self.win = w; self.panel = pnl; self.ball = ball;

    [ball addTarget:self action:@selector(onBallTap:) forControlEvents:UIControlEventTouchUpInside];
    [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(onBallPan:)]];
    [pnl addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(onPanelPan:)]];
    [x addTarget:self action:@selector(onClose:) forControlEvents:UIControlEventTouchUpInside];
    [sk addTarget:self action:@selector(onKill:) forControlEvents:UIControlEventValueChanged];
    [ss addTarget:self action:@selector(onSpeedSw:) forControlEvents:UIControlEventValueChanged];
    [sg addTarget:self action:@selector(onSeg:) forControlEvents:UIControlEventValueChanged];
    [NSTimer scheduledTimerWithTimeInterval:0.8 target:self
                                   selector:@selector(maybeShow) userInfo:nil repeats:YES];
    L("ui: helper install ok");
}

- (void)maybeShow {
    UIWindow *w = self.win;
    if (!w || w.hidden) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    if (w.bounds.size.width != sb.size.width || w.bounds.size.height != sb.size.height)
        w.frame = sb;
    if (!self.shown) {
        self.shown = YES;
        self.ball.hidden = NO;
        [w bringSubviewToFront:self.ball];
        L("ui: 悬浮球已显示");
    } else if (!self.panel.hidden) {
        [w bringSubviewToFront:self.panel];
    }
}
@end

// ───────────────────────── 构建 UI ─────────────────────────
static void gzz_build_ui(void) {
    CGRect sb = [UIScreen mainScreen].bounds;

    GzzOverlayWin *w = [[GzzOverlayWin alloc] initWithFrame:sb];
    w.windowLevel = UIWindowLevelNormal + 10;
    w.backgroundColor = [UIColor clearColor];
    w.opaque = NO;
    GzzOverlayVC *vc = [GzzOverlayVC new];
    w.rootViewController = vc;
    w.hidden = NO;                       // ⚠️ 绝不 makeKeyAndVisible
    g_win = w;
    vc.view.backgroundColor = [UIColor clearColor];
    L("ui: 可穿透 overlay 已创建 (level=%.0f)", w.windowLevel);

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
    [g_ball setTitle:@"战" forState:UIControlStateNormal];
    g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    g_ball.hidden = YES;                 // 由 maybeShow 延迟显示
    [vc.view addSubview:g_ball];

    // 面板
    CGFloat pw = 264, ph = 288;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(12, 90, pw, ph)];
    g_panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.93];
    g_panel.layer.cornerRadius = 14;
    g_panel.layer.borderWidth = 1;
    g_panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    g_panel.hidden = YES;
    [vc.view addSubview:g_panel];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, pw - 60, 22)];
    t.text = @"古代战争助手 v3";
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:15];
    [g_panel addSubview:t];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(pw - 42, 6, 34, 26);
    [x setTitle:@"✕" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:17];
    [g_panel addSubview:x];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(14, 38, 150, 30)];
    l1.text = @"秒杀 / 自动跳过";
    l1.textColor = [UIColor colorWithWhite:0.93 alpha:1];
    l1.font = [UIFont systemFontOfSize:13.5];
    [g_panel addSubview:l1];
    g_swKill = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 66, 38, 51, 31)];
    g_swKill.transform = CGAffineTransformMakeScale(0.86, 0.86);
    [g_panel addSubview:g_swKill];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(14, 72, 150, 30)];
    l2.text = @"全局加速";
    l2.textColor = [UIColor colorWithWhite:0.93 alpha:1];
    l2.font = [UIFont systemFontOfSize:13.5];
    [g_panel addSubview:l2];
    g_swSpeed = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 66, 72, 51, 31)];
    g_swSpeed.transform = CGAffineTransformMakeScale(0.86, 0.86);
    [g_panel addSubview:g_swSpeed];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(14, 106, pw - 28, 16)];
    l3.text = @"加速倍率";
    l3.textColor = [UIColor colorWithWhite:0.66 alpha:1];
    l3.font = [UIFont systemFontOfSize:11.5];
    [g_panel addSubview:l3];
    g_segSpeed = [[UISegmentedControl alloc] initWithItems:@[@"1x", @"2x", @"3x", @"5x"]];
    g_segSpeed.frame = CGRectMake(12, 122, pw - 24, 28);
    g_segSpeed.selectedSegmentIndex = 1;      // 默认 2x
    [g_panel addSubview:g_segSpeed];

    g_stat = [[UILabel alloc] initWithFrame:CGRectMake(12, 156, pw - 24, 56)];
    g_stat.numberOfLines = 0;
    g_stat.textColor = [UIColor colorWithRed:0.55 green:0.92 blue:0.62 alpha:1];
    g_stat.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    g_stat.text = @"…";
    [g_panel addSubview:g_stat];

    NSArray *titles = @[@"重置计数", @"扫描战斗类"];
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12 + i * ((pw - 36) / 2 + 12), 216, (pw - 36) / 2, 34);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        b.backgroundColor = i == 0
            ? [UIColor colorWithRed:0.20 green:0.35 blue:0.60 alpha:1]
            : [UIColor colorWithRed:0.62 green:0.30 blue:0.16 alpha:1];
        b.layer.cornerRadius = 8;
        b.tag = 100 + i;
        [b addTarget:H action:@selector(onBtn:) forControlEvents:UIControlEventTouchUpInside];
        [g_panel addSubview:b];
    }

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(12, 258, pw - 24, 18)];
    tip.text = @"联机玩法(竞技场/跨服)勿开秒杀";
    tip.textColor = [UIColor colorWithRed:1 green:0.55 blue:0.35 alpha:1];
    tip.font = [UIFont systemFontOfSize:10];
    [g_panel addSubview:tip];

    [H install:w panel:g_panel ball:g_ball
         swKill:g_swKill swSpeed:g_swSpeed seg:g_segSpeed closeBtn:x];
}

// ───────────────────────── 入口 ─────────────────────────
@interface GzzTickKeeper : NSObject
+ (void)fire;
@end
@implementation GzzTickKeeper
+ (void)fire { gzz_tick(); }
@end

__attribute__((constructor))
static void gzz_ctor(void) {
    L("ctor: GZZ v3 载入 (pid=%d)", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gzz_build_ui();
        gzz_find_base();
        [NSTimer scheduledTimerWithTimeInterval:0.5 target:[GzzTickKeeper class]
                                       selector:@selector(fire) userInfo:nil repeats:YES];
        L("ctor: tick 启动");
    });
}
