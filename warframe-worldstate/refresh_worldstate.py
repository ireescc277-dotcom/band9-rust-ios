# -*- coding: utf-8 -*-
"""
Warframe 世界状态看板 - 数据刷新 / 本地代理

用法：
  python refresh_worldstate.py            抓取最新 worldState.php 并写回 HTML（离线快照）
  python refresh_worldstate.py --serve    启动 http://127.0.0.1:8777 ，页面可实时刷新
  python refresh_worldstate.py --dict     同时重新构建中文字典（需能访问 GitHub，可选 zhconv）
  python refresh_worldstate.py --from-file worldstate.json [--dict-dir ./wfdict]
                                          用本地文件生成（网络不可用时）

说明：官方接口不带 CORS 头，浏览器无法直连，因此页面内置快照；
      --serve 模式由本脚本做同域反向代理，页面点击「刷新数据」即可拿到实时数据。
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HTML = ROOT / "warframe-worldstate.html"
CACHE = ROOT / ".workbuddy" / "wf_dict.json"
API = "https://api.warframe.com/cdn/worldState.php"
GH = "https://raw.githubusercontent.com/WFCD/warframe-worldstate-data/master/data/zh/"

FIELD_DESC = {
    "WorldSeed": "世界种子，客户端用于校验与生成随机内容",
    "Version": "世界状态协议版本号",
    "MobileVersion": "移动端客户端版本",
    "BuildLabel": "当前构建标签（时间 / 哈希）",
    "Time": "本次快照生成时间，Unix 秒",
    "Events": "社区公告、新闻与多语言推广文案，Prop 为跳转链接",
    "Goals": "全服社区目标与活动进度（HealthPct、Count、Goal）",
    "Alerts": "限时警报任务，含任务信息与奖励",
    "Sorties": "每日突击，三阶段任务与词缀，首领 Boss",
    "LiteSorties": "执政官猎杀（Archon Hunt），三阶段任务，首领为执政官",
    "SyndicateMissions": "各集团每日刷新的任务节点集合",
    "ActiveMissions": "虚空裂隙任务，Modifier 为遗物纪元，Hard 表示钢铁之路",
    "GlobalUpgrades": "全局增益，如双倍击杀经验",
    "FlashSales": "商城限时促销条目（含大量长期组合包）",
    "SkuSales": "SKU 级促销，通常为空",
    "InGameMarket": "游戏内商城落地页分类与商品",
    "Invasions": "入侵事件，攻防双方进度与各自奖励",
    "HubEvents": "中继站事件，通常为空",
    "NodeOverrides": "星图节点显隐覆写",
    "VoidTraders": "虚空商人 Baro，出现时间、位置与商品清单",
    "PrimeVaultTraders": "Prime 宝库商人，上架物品与轮换排期",
    "VoidStorms": "九重天虚空风暴节点与强度层",
    "PrimeAccessAvailability": "Prime Access 当前售卖状态",
    "DailyDeals": "每日特惠，折扣、价格与限量库存",
    "LibraryInfo": "资料库 / Simaris 最近完成的研究目标",
    "PVPChallengeInstances": "Conclave 每日与每周挑战实例",
    "PersistentEnemies": "持久敌人（追猎者一类），通常为空",
    "PVPAlternativeModes": "PVP 替代模式，通常为空",
    "PVPActiveTournaments": "PVP 锦标赛，通常为空",
    "ProjectPct": "建造项目进度百分比数组",
    "ConstructionProjects": "氏族 / 社区建造项目，通常为空",
    "TwitchPromos": "Twitch 掉宝推广，通常为空",
    "ExperimentRecommended": "实验性推荐内容，通常为空",
    "EndlessXpSchedule": "无尽任务经验加成轮换与可选奖励",
    "ForceLogoutVersion": "强制客户端下线的版本号，0 表示不强制",
    "FeaturedGuilds": "推荐展示的氏族信息",
    "SeasonInfo": "赛季（Nightwave 类）信息、参数与活跃挑战",
    "KnownCalendarSeasons": "日历季节配置与每日条目",
    "Conquests": "征服模式任务、难度与变量",
    "Descents": "Descent 模式挑战组（暂无统一中文译名）",
    "Tmp": "临时多语言文本，本身是字符串化的 JSON",
    "WeeklyVaultBonusRewards": "周常宝库加成星球与奖励",
}

ITEMS = {
    "Forma": "塑形块 Forma", "Kuva": "赤毒 Kuva", "50000Credits": "50000 现金",
    "RoadToTauEventResource": "通往 Tau 活动资源", "SortieRewards": "突击奖励池",
    "ArchonSortieRewards": "执政官突击奖励池", "BioComponent": "生物组件",
    "EnergyComponent": "能量组件", "OrokinCatalyst": "奥罗金催化剂",
    "OrokinReactor": "奥罗金反应堆", "ExilusAdapter": "Exilus 槽连接器",
    "NitainExtract": "尼坦精华", "Aya": "阿耶 Aya", "VoidTraces": "虚空印痕",
    "Endo": "融合单元 Endo", "Cryotic": "低温合金", "Oxium": "氧化合金",
    "Tellurium": "碲元素", "ArgonCrystal": "氩结晶", "NeuralSensors": "神经元",
    "OrokinCell": "奥罗金电池", "Morphics": "形态场", "Gallium": "镓",
    "ControlModule": "控制模块", "AlloyPlate": "合金板", "Ferrite": "铁氧体",
    "NanoSpores": "纳米孢子", "Circuits": "电路板", "PolymerBundle": "聚合束",
    "Plastids": "质体", "Rubedo": "红化结晶", "Salvage": "回收金属",
    "Neurodes": "神经电极", "Neurode": "神经电极",
    "SnipetronVandalBlueprint": "Snipetron Vandal 蓝图（狙击枪）",
    "KarakWraithBarrel": "卡拉卡·亡魂 枪管", "VandalCrpBFG": "Vandal 系 Corpus 武器",
    "Fist": "拳套类武器", "HeatFissuresEventScore": "已封印裂缝数",
}

ITEM_RULES = {
    "/Bundles/": "组合包", "/Packages/": "礼包", "/Packs/": "礼包",
    "/AvatarImages/": "头像", "/Glyph": "头像图案", "/Skins/": "外观",
    "/Ephemera": "幻纹", "/Syandana": "披饰", "/Sigil": "纹章",
    "/Emblem": "徽章", "/Armor/": "护甲", "/Armour/": "护甲",
    "/Tattoo": "纹身", "/Display": "展示物", "/Deco": "装饰",
    "/Recipes/": "蓝图", "/Weapons/": "武器", "/Warframes/": "战甲",
    "/StoreItems/Types/": "商城物品", "/Upgrades/": "强化", "/Mods/": "MOD",
    "/Helmets/": "头盔", "/Sugatra": "武器挂饰", "/Palette": "配色",
    "/Relics/": "遗物", "/Resources/": "资源", "/Blueprints/": "蓝图",
}

HUB_NAMES = {
    "SaturnHUB": "土星中继站", "TradeHUB1": "贸易中继站", "EarthHUB": "地球中继站",
    "EuropaHUB": "木卫二中继站", "ErisHUB": "阋神星中继站", "VenusHUB": "金星中继站",
    "MercuryHUB": "水星中继站", "MarsHUB": "火星中继站", "JupiterHUB": "木星中继站",
    "NeptuneHUB": "海王星中继站", "PlutoHUB": "冥王星中继站", "SednaHUB": "塞德娜中继站",
    "UranusHUB": "天王星中继站", "CeresHUB": "谷神星中继站", "LuaHUB": "月球中继站",
    "VoidHUB": "虚空中继站", "RelayHUB": "中继站",
}

# 人工校对表：WFCD 的 zh 字典里有一部分是未翻译的英文原文或错字，
# 这里按页面实际用到的 /Lotus/Language/... 路径逐条覆盖（优先级最高）。
LANG_FIX = {
    # 入侵
    "/Lotus/Language/Menu/CorpusInvasionGeneric": "Corpus 入侵",
    "/Lotus/Language/Menu/InfestedInvasionGeneric": "疫变体入侵",
    "/Lotus/Language/Menu/GrineerInvasionGeneric": "Grineer 入侵",
    "/Lotus/Language/Menu/InfestedInvasionBoss": "疫变体首领入侵",
    # 社区目标 / 活动（字典里这几条是英文原句，按字面译）
    "/Lotus/Language/G1Quests/HeatFissuresEventName": "热美亚裂缝",
    "/Lotus/Language/G1Quests/HeatFissuresEventDesc": "封印热美亚裂缝，阻止熔岩蔓延。",
    "/Lotus/Language/G1Quests/HeatFissuresEventScore": "已封印裂缝数",
    "/Lotus/Language/TauPrologue/RoadToTauEventName": "纪元行动：通往 Tau",
    "/Lotus/Language/TauPrologue/RoadToTauShortEventDesc": "在阋神星周边的疫变体节点击败感染者，收割月之血肉！",
    "/Lotus/Language/TauPrologue/RoadToTauEventScore": "全球收割进度",
    "/Lotus/Language/TauPrologue/EventAlertTitle": "检测到月之血肉聚集点",
    "/Lotus/Language/GameModes/RecurringNightwave": "循环赛季活动",
    "/Lotus/Language/GameModes/RecurringGhoulAlert": "复发的食尸鬼警报",
    "/Lotus/Language/GameModes/RecurringGhoulAlertDesc": "周期性出现的食尸鬼警报活动。",
    # 地点
    "/Lotus/Language/Locations/Earth": "地球",
    "/Lotus/Language/Locations/Fortress": "Kuva 要塞",
    # 商城落地页分类
    "/Lotus/Language/Store/NewPlayerCategoryTitle": "新手推荐",
    "/Lotus/Language/Menu/Store_New": "新品上架",
    "/Lotus/Language/Store/CommunityCategoryTitle": "社区精选",
    "/Lotus/Language/Menu/StorePopular": "热门商品",
    "/Lotus/Language/Menu/Store_Tennogen": "TennoGen 创意工坊",
    "/Lotus/Language/Store/HeirloomCategoryTitle": "传承典藏",
    "/Lotus/Language/Menu/Store_Sale": "特惠促销",
    "/Lotus/Language/Menu/Store_Wishlist": "愿望清单",
    "/Lotus/Language/Store/Store_PremiumBundles": "高级组合包",
    # 社区
    "/Lotus/Language/CommunityMessages/JoinDiscord": "加入官方 Discord",
}

FACTION_FIX = {
    "FC_GRINEER": "Grineer 克隆尼", "FC_CORPUS": "Corpus 科普斯",
    "FC_INFESTATION": "Infested 疫变体", "FC_CORRUPTED": "堕落者",
    "FC_OROKIN": "奥罗金", "FC_SENTIENT": "Sentient 心智者",
    "FC_TENNO": "Tenno 天诺", "FC_MITW": "墙中人",
    "FC_NARMER": "Narmer 纳尔默", "FC_NEUTRAL": "中立",
    "FC_UMBRA": "Umbra 暗影",
    # 1999 版本新增派系尚无统一中文译名，保留英文
    "FC_SCALDRA": "Scaldra", "FC_TECHROT": "Techrot",
}

# 任务类型：WFCD 的 zh 版有几条漏译 / 半英文
MISSION_FIX = {
    "MT_PURIFY": "疫变体资源回收",
    "MT_ASCENSION": "升腾（Ascension）",
    "MT_ENDLESS_CAPTURE": "Legacyte 收割（无尽捕获）",
}

# 集团名：修正字典里的错字与漏译
SYND_FIX = {
    "VoxSyndicate": "索拉里斯之声",      # 原字典误作「索里拉斯之声」
    "CetusSyndicate": "奥斯特隆人（希图斯）",  # 原字典为英文 Ostrons
    "HexSyndicate": "The Hex 六人组",   # 原字典为英文 The Hex
    "AssassinsSyndicate": "刺客集团",
    "EventSyndicate": "活动集团",
}

UPGRADE_FIX = {"GAMEPLAY_MONEY_REWARD_AMOUNT": "现金奖励数量"}
OPERATION_FIX = {"MULTIPLY": {"value": "乘以", "symbol": "×"}}

HAS_HAN = re.compile(r"[\u4e00-\u9fff]")


def fix_punct(s):
    """统一标点：半角括号、多余空格、全角冒号变体。"""
    if not isinstance(s, str):
        return s
    return (s.replace("次要 限定", "副武器限定")
             .replace(" 限定", "限定")
             .replace("武器限定：", "仅限")
             .replace("(", "（").replace(")", "）")
             .replace("︰", "：").replace("﹕", "："))


def fix_wording(s):
    """在标点统一之外，补中英文之间的空格，并修正「委员」误译。"""
    s = fix_punct(s).replace("委员", "议员") if isinstance(s, str) else s
    if not isinstance(s, str):
        return s
    s = re.sub(r"([A-Za-z0-9])([\u4e00-\u9fff])", r"\1 \2", s)
    s = re.sub(r"([\u4e00-\u9fff])([A-Za-z0-9])", r"\1 \2", s)
    return s

DICT_FILES = ["solNodes", "missionTypes", "syndicatesData", "factionsData",
              "upgradeTypes", "operationTypes", "sortieData", "fissureModifiers", "languages"]


def curl(url, timeout=40):
    """依次尝试 Windows curl、urllib（均读取系统代理），任一成功即返回。"""
    errs = []
    try:
        p = subprocess.run(["curl", "-sS", "-L", "--max-time", str(timeout),
                            "-H", "User-Agent: Mozilla/5.0", url], capture_output=True)
        if p.returncode == 0 and p.stdout:
            return p.stdout.decode("utf-8-sig", "ignore")
        errs.append("curl: " + p.stderr.decode("utf-8", "ignore")[:120])
    except Exception as e:
        errs.append("curl: " + str(e))
    try:
        import urllib.request
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8-sig", "ignore")
    except Exception as e:
        errs.append("urllib: " + str(e))
    raise RuntimeError("网络请求失败（" + " | ".join(errs) + "）；可改用 --from-file 指定本地 JSON")


def to_simplified(x):
    try:
        from zhconv import convert
        return convert(x, "zh-cn") if isinstance(x, str) else x
    except ImportError:
        return x


def val(d, k):
    v = d.get(k) if isinstance(d, dict) else None
    if isinstance(v, dict):
        return to_simplified(v.get("value", v.get("name", "")))
    return to_simplified(v) if isinstance(v, str) else v


def build_dict(raw_ws, dict_dir=None):
    src = {}
    for name in DICT_FILES:
        try:
            if dict_dir:
                src[name] = json.loads((Path(dict_dir) / (name + ".json")).read_text(encoding="utf-8-sig"))
            else:
                src[name] = json.loads(curl(GH + name + ".json"))
            print("  字典 %-18s %d 条" % (name, len(src[name])))
        except Exception as e:
            print("  字典 %-18s 读取失败(%s)，跳过" % (name, e))
            src[name] = {}

    nodes = {k: {"n": fix_punct(to_simplified(v.get("value", k))),
                 "e": to_simplified(v.get("enemy", "")),
                 "t": to_simplified(v.get("type", ""))}
             for k, v in src["solNodes"].items()}
    if nodes.get("SolNode0", {}).get("n") == "SolNode0":
        nodes["SolNode0"]["n"] = "远古惩戒（特殊节点）"

    mission = {k: val(src["missionTypes"], k) for k in src["missionTypes"]}
    mission.update(MISSION_FIX)
    factions = {k: val(src["factionsData"], k) for k in src["factionsData"]}
    factions.update(FACTION_FIX)
    synd = {k: to_simplified((v.get("name") if isinstance(v, dict) else v) or k)
            for k, v in src["syndicatesData"].items()}
    synd.update(SYND_FIX)

    sd = src["sortieData"] or {}
    # 只采用字典里真正译成中文的条目；英文原文不会覆盖人工译文
    lang = {}
    used = set(re.findall(r"/Lotus/Language/[A-Za-z0-9_/]+", raw_ws))
    for k in used:
        if k in src["languages"]:
            v = to_simplified(val(src["languages"], k))
            if isinstance(v, str) and HAS_HAN.search(v):
                lang[k] = v
    lang.update(LANG_FIX)

    upgrades = {k: val(src["upgradeTypes"], k) for k in src["upgradeTypes"]}
    upgrades.update(UPGRADE_FIX)
    ops = dict(src["operationTypes"] or {})
    ops.update(OPERATION_FIX)

    return {
        "nodes": nodes, "missionTypes": mission, "factions": factions,
        "syndicates": synd,
        "sortieModifiers": {k: fix_wording(to_simplified(v)) for k, v in (sd.get("modifierTypes") or {}).items()},
        "sortieDesc": {k: fix_punct(to_simplified(v)) for k, v in (sd.get("modifierDescriptions") or {}).items()},
        "sortieBosses": {k: ({"name": fix_wording(to_simplified(v.get("name", k))),
                             "faction": v.get("faction", "")} if isinstance(v, dict) else {"name": fix_wording(to_simplified(v)), "faction": ""})
                         for k, v in (sd.get("bosses") or {}).items()},
        "upgrades": upgrades,
        "operations": ops,
        "tiers": {k: val(src["fissureModifiers"], k) for k in src["fissureModifiers"]},
        "lang": lang, "items": ITEMS, "itemRules": ITEM_RULES,
        "hubNames": HUB_NAMES, "fieldDesc": FIELD_DESC,
    }


def json_for_script(obj):
    # 防止 JSON 内容提前闭合 <script>
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")


def inject(html, dict_obj, data_raw):
    if not re.search(r'<script id="ws-dict"[^>]*>.*?</script>', html, re.S):
        raise RuntimeError("HTML 中未找到 ws-dict 占位节点")
    html = re.sub(r'(<script id="ws-dict"[^>]*>).*?(</script>)',
                  lambda m: m.group(1) + json_for_script(dict_obj) + m.group(2),
                  html, count=1, flags=re.S)
    data = json.dumps(json.loads(data_raw), ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    html = re.sub(r'(<script id="ws-data"[^>]*>).*?(</script>)',
                  lambda m: m.group(1) + data + m.group(2),
                  html, count=1, flags=re.S)
    return html


def fetch_worldstate(from_file=None):
    if from_file:
        print("  从本地文件读取 " + str(from_file))
        raw = Path(from_file).read_text(encoding="utf-8-sig")
    else:
        print("  正在抓取 " + API)
        raw = curl(API, 30)
    j = json.loads(raw)
    if "Time" not in j:
        raise RuntimeError("响应中缺少 Time 字段，可能被 CDN 拦截")
    return raw, j


def serve():
    import http.server
    import urllib.parse

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(ROOT), **kw)

        def do_GET(self):
            if urllib.parse.urlparse(self.path).path == "/api/worldstate":
                try:
                    raw, _ = fetch_worldstate()
                    body = raw.encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Exception as e:
                    self.send_error(502, str(e))
                return
            return super().do_GET()

        def do_HEAD(self):
            if urllib.parse.urlparse(self.path).path == "/api/worldstate":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                return
            return super().do_HEAD()

        def log_message(self, fmt, *args):
            if "/api/worldstate" in (args[0] if args else ""):
                print("  [代理] " + fmt % args)

    print("本地服务已启动： http://127.0.0.1:8777/warframe-worldstate.html")
    print("页面「刷新数据」按钮现在可用（Ctrl+C 结束）")
    http.server.ThreadingHTTPServer(("127.0.0.1", 8777), Handler).serve_forever()


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv and sys.argv.index(name) + 1 < len(sys.argv) else None


def main():
    if "--serve" in sys.argv:
        serve()
        return
    html = HTML.read_text(encoding="utf-8")
    raw, j = fetch_worldstate(arg("--from-file"))
    print("  快照时间 %s，%d 个顶层字段，%d 字节" % (j["Time"], len(j), len(raw)))

    if "--dict" in sys.argv or "/*__DICT__*/" in html:
        print("构建中文字典：")
        d = build_dict(raw, arg("--dict-dir"))
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        CACHE.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        print("  字典已缓存 -> %s" % CACHE)
    else:
        d = None

    if d is not None:
        html = inject(html, d, raw)
    else:
        data = json.dumps(json.loads(raw), ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
        html = re.sub(r'(<script id="ws-data"[^>]*>).*?(</script>)',
                      lambda m: m.group(1) + data + m.group(2), html, count=1, flags=re.S)

    HTML.write_text(html, encoding="utf-8")
    print("已更新 -> %s (%d 字节)" % (HTML, len(html.encode("utf-8"))))
    print("直接双击打开即可查看；如需实时数据，运行 python refresh_worldstate.py --serve")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("失败：" + str(e))
        sys.exit(1)
