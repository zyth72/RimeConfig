-- @amzxyz  https://github.com/amzxyz/rime_wanxiang
-- 功能 A：候选文本中的转义序列格式化（始终开启）
--         \n \t \r \\ \s(空格) \d(-)
-- 功能 B：候选重排（仅编码长度 2..6 时）
--         - 第一候选不动
--         - 其余按组输出：①不含字母(table/user_table) → ②其他
--         - 若第二候选为 table/user_table，则不排序，直接透传
-- 功能 C：成对符号包裹（触发：最后分段完整消耗且出现 prefix\suffix；suffix 命中映射时吞掉 \suffix）
-- 缓存/锁定：
--   - 未锁定时记录第一候选为缓存
--   - 出现 prefix\suffix 且 prefix 非空 ⇒ 锁定
--   - 兜底重建，当有些单词类型输入斜杠后不产出候选就将前面产生的进行构造候选
--   - 输入为空时释放缓存/锁定
-- 功能D 字符集过滤，默认8105+𰻝𰻝，可以在方案中定义黑白名单来实现用户自己的范围微调addlist: []和blacklist: [𰻝, 𰻞]
-- 功能E 由于在混输场景中输入comment commit等等之类的英文时候，由于直接辅助码的派生能力，会将三个好不想干的单字组合在一起，这会造成不好的体验
--      因此在首选已经是英文的时候，且type=completion且大于等于4个字符，这个时候后面如果有type=sentence的派生词则直接干掉，这个还要依赖，表翻译器
--      权重设置与主翻译器不可相差太大

local wanxiang = require("wanxiang")
local M = {}

-- 性能优化：本地化字符串函数
local byte, find, gsub, upper, sub = string.byte, string.find, string.gsub, string.upper, string.sub
local utf8_codes = utf8.codes -- 本地化 utf8 迭代器

local function fast_type(c)
    local t = c.type
    if t then return t end
    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

local function is_table_type(c)
    local t = fast_type(c)
    return t == "table" or t == "user_table" or t == "fixed"
end

local function has_english_token_fast(s)
    local len = #s
    for i = 1, len do
        local b = byte(s, i)
        if b < 0x80 then
            -- A-Z (0x41-0x5A) or a-z (0x61-0x7A)
            if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
                return true
            end
        end
    end
    return false
end
-- 纯ASCII判定
local function is_english_candidate(cand)
    local txt = cand and cand.text
    if not txt or txt == "" then return false end
    if not has_english_token_fast(txt) then
        return false
    end
    -- 使用局部变量 find，而非 string.find
    if find(txt, "[\128-\255]") then
        return false
    end
    return true
end

-- 1. 内部常量与工具函数
local escape_map = {
    ["\\n"] = "\n",            -- 换行
    ["\\r"] = "\r",            -- 回车
    ["\\t"] = "\t",            -- 制表符
    ["\\s"] = " ",             -- 空格
    ["\\z"] = "\226\128\139",  -- 零宽空格
}

local utf8_char_pattern = "[%z\1-\127\194-\244][\128-\191]*"

-- 时辰数据：每个时辰2小时，共8刻，每刻15分钟
local shichen_data = {
    {name = "子时", start_hour = 23, end_hour = 1},
    {name = "丑时", start_hour = 1, end_hour = 3},
    {name = "寅时", start_hour = 3, end_hour = 5},
    {name = "卯时", start_hour = 5, end_hour = 7},
    {name = "辰时", start_hour = 7, end_hour = 9},
    {name = "巳时", start_hour = 9, end_hour = 11},
    {name = "午时", start_hour = 11, end_hour = 13},
    {name = "未时", start_hour = 13, end_hour = 15},
    {name = "申时", start_hour = 15, end_hour = 17},
    {name = "酉时", start_hour = 17, end_hour = 19},
    {name = "戌时", start_hour = 19, end_hour = 21},
    {name = "亥时", start_hour = 21, end_hour = 23},
}

-- 刻数名称：每个时辰有8刻
local ke_names = {"初刻", "二刻", "三刻", "四刻", "五刻", "六刻", "七刻", "八刻"}

-- 获取时辰和刻数
local function get_shichen_and_ke(hour, min)
    local total_minutes = hour * 60 + min
    
    -- 遍历所有时辰
    for _, shichen in ipairs(shichen_data) do
        local shichen_name = shichen.name
        local start_hour = shichen.start_hour
        local end_hour = shichen.end_hour
        
        -- 计算时辰的起始和结束分钟数
        local start_minutes = start_hour * 60
        local end_minutes = end_hour * 60
        
        -- 处理跨天的子时
        if start_hour > end_hour then
            end_minutes = end_hour * 60 + 1440  -- 第二天的时间
        end
        
        -- 检查是否在当前时辰内
        if total_minutes >= start_minutes and total_minutes < end_minutes then
            -- 计算在此时辰内的分钟偏移量
            local offset_minutes = total_minutes - start_minutes
            
            -- 计算刻数索引 (0-7对应初刻-八刻)
            -- 每刻15分钟，四舍五入到最近的刻
            local ke_index = math.floor(offset_minutes / 15)
            
            -- 边界处理：当offset_minutes为120时，应该是八刻，所以索引为7
            if ke_index >= 8 then
                ke_index = 7
            end
            
            return shichen_name, ke_names[ke_index + 1]  -- +1因为Lua数组从1开始
        end
    end
    
    return "未知时辰", "未知刻"
end

-- 2. 核心：处理动态时间（只负责替换，不负责保护）
local function process_datetime_internal(s)
    local dt = os.date("*t")
    
    -- 获取时辰和刻数
    local current_shichen, current_ke = get_shichen_and_ke(dt.hour, dt.min)
    
    local week_table_big = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"}
    local week_table_small = {"周日", "周一", "周二", "周三", "周四", "周五", "周六"}
    
    local h12 = dt.hour % 12; if h12 == 0 then h12 = 12 end
    local ampm = (dt.hour < 12) and "am" or "pm"
    local raw_tz = os.date("%z") or "+0800"
    local tz_colon = raw_tz:sub(1,3) .. ":" .. raw_tz:sub(4,5)
    
    -- 计算中文时段 A
    local zh_period
    local h = dt.hour
    if h < 6 then zh_period = "凌晨"
    elseif h < 12 then zh_period = "上午"
    elseif h < 13 then zh_period = "中午"
    elseif h < 18 then zh_period = "下午"
    else zh_period = "晚上" end

    local time_map = {
        Y = string.format("%04d", dt.year),
        y = string.format("%02d", dt.year % 100),
        m = string.format("%02d", dt.month),
        d = string.format("%02d", dt.day),
        N = tostring(dt.month),  -- 月份不带零（用\N避开\n换行冲突）
        j = tostring(dt.day),
        W = week_table_big[dt.wday],
        w = week_table_small[dt.wday],
        H = string.format("%02d", dt.hour),
        G = tostring(dt.hour),
        I = string.format("%02d", h12),
        l = tostring(h12),
        T = current_shichen,
        K = current_ke,
        M = string.format("%02d", dt.min),
        S = string.format("%02d", dt.sec),
        p = ampm,
        P = ampm:upper(),
        O = tz_colon,
        o = raw_tz,
        A = zh_period
    }

    return s:gsub("\\(%a)", function(char)
        return time_map[char] or char 
    end)
end

-- 3. 主入口：全局保护 [[]] 并执行所有转义逻辑
local function apply_escape_fast(text)
    -- 性能护航：不含反斜杠直接返回
    if not text or not string.find(text, "\\", 1, true) then
        return text, false
    end

    -- 第一步：保护 [[...]]
    local blocks = {}
    local s = text:gsub("%[%[(.-)%]%]", function(txt)
        blocks[#blocks+1] = txt
        return "\0BLK" .. #blocks .. "\0"
    end)

    -- 第二步：处理基础转义 (\n, \t, \s, \z 等)
    s = s:gsub("\\[ntrsz]", escape_map)

    -- 第三步：处理字符重复 (a\3 => aaa)
    s = s:gsub("(" .. utf8_char_pattern .. ")\\(%d+)", function(char, count)
        local n = tonumber(count)
        if n and n > 0 and n < 200 then
            return string.rep(char, n)
        end
        return char .. "\\" .. count
    end)

    -- 第四步：处理动态时间占位符 (\Y, \T, \A 等)
    s = process_datetime_internal(s)

    -- 第五步：还原 [[...]]
    s = s:gsub("\0BLK(%d+)\0", function(i)
        return blocks[tonumber(i)] or ""
    end)

    return s, s ~= text
end
local function format_and_autocap(cand)
    local text = cand.text
    if not text or text == "" then return cand end
    local t2, changed = apply_escape_fast(text)
    if not changed then return cand end
    local nc = Candidate(cand.type, cand.start, cand._end, t2, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

local function clone_candidate(c)
    local nc = Candidate(c.type, c.start, c._end, c.text, c.comment)
    nc.preedit = c.preedit
    return nc
end
--  包裹映射
local default_wrap_map = {
    -- 单字母：常用成对括号/引号（每项恰好两个字符）
    a = "[]",        -- 方括号
    b = "【】",       -- 黑方头括号
    c = "❲❳",        -- 双大括号 / 装饰括号
    d = "〔〕",       -- 方头括号
    e = "⟮⟯",        -- 小圆括号 / 装饰括号
    f = "⟦⟧",        -- 双方括号 / 数学集群括号
    g = "「」",       -- 直角引号
    -- h 预留用于 Markdown 一级标题
    i = "『』",       -- 双直角引号
    j = "<>",         -- 尖括号
    k = "《》",       -- 书名号（双）
    l = "〈〉",       -- 书名号（单）
    m = "‹›",         -- 法文单书名号
    n = "«»",         -- 法文双书名号
    o = "⦅⦆",          -- 白圆括号
    p = "⦇⦈",         -- 白方括号
    q = "()",         -- 圆括号
    r = "|儿",          --儿化候选
    s = "［］",        -- 全角方括号
    t = "⟨⟩",         -- 数学角括号
    u = "〈〉",        -- 数学尖括号
    v = "❰❱",        -- 装饰角括号
    w = "（）",       -- 全角圆括号
    x = "｛｝",       -- 全角花括号
    y = "⟪⟫",       -- 双角括号
    z = "{}",        -- 花括号

    --  扩展括号族 / 引号
    dy = "''",       -- 英文单引号
    sy = "\"\"",     -- 英文双引号
    zs = "“”",       -- 中文弯双引号
    zd = "‘’",       -- 中文弯单引号
    fy = "``",       -- 反引号

    --  双字母括号族
    aa = "〚〛",      -- 双中括号
    bb = "〘〙",      -- 双中括号（小）
    cc = "〚〛",      -- 双中括号（重复，可用于 Lua 匹配）
    dd = "❨❩",      -- 小圆括号装饰
    ee = "❪❫",      -- 小圆括号装饰
    ff = "❬❭",      -- 小尖括号装饰
    gg = "⦉⦊",      -- 双弯方括号
    ii = "⦍⦎",      -- 双弯方括号
    jj = "⦏⦐",      -- 双弯方括号
    kk = "⦑⦒",      -- 双弯方括号
    ll = "❮❯",      -- 小尖括号装饰
    mm = "⌈⌉",      -- 上取整 / 数学符号
    nn = "⌊⌋",      -- 下取整 / 数学符号
    oo = "⦗⦘",      -- 双方括号装饰（补齐）
    pp = "⦙⦚",      -- 双方括号装饰（补齐）
    qq = "⟬⟭",      -- 小双角括号
    rr = "❴❵",      -- 花括号装饰
    ss = "⌜⌝",      -- 数学上角符号
    tt = "⌞⌟",      -- 数学下角符号
    uu = "⸢⸣",      -- 装饰方括号
    vv = "⸤⸥",      -- 装饰方括号
    ww = "﹁﹂",      -- 中文书名号 / 注释引号
    xx = "﹃﹄",      -- 中文书名号 / 注释引号
    yy = "⌠⌡",      -- 数学 / 程序符号
    zz = "⟅⟆",      -- 数学 / 装饰括号

    --  Markdown / 标记
    md = "**|**",      -- Markdown 粗体
    jc = "**|**",      -- 加粗
    it = "__|__",      -- 斜体
    st = "~~|~~",      -- 删除线
    eq = "==|==",      -- 高亮
    ln = "`|`",        -- 行内代码
    cb = "```|```",    -- 代码块
    qt = "> |",        -- 引用
    ul = "- |",        -- 无序列表项
    ol = "1. |",       -- 有序列表项
    lk = "[|](url)",   -- 链接
    im = "![|](img)",  -- 图片
    h = "# |",         -- 一级标题
    hh = "## |",       -- 二级标题
    hhh = "### |",     -- 三级标题
    hhhh = "#### |",   -- 四级标题
    sp = "\\|",        -- 反斜杠转义
    br = "|  ",        -- 换行
    cm = "<!--|-->",   -- 注释

    --  运算与标记符
    pl = "++",
    mi = "--",
    sl = "//",
    bs = "\\\\",
    at = "@@",
    dl = "$$",
    pc = "%%",
    an = "&&",
    cr = "^^",
    cl = "::",
    sc = ";;",
    ex = "!!",
    qu = "??",
    sb = "sb",
}

local function load_mapping_from_config(config)
    local symbol_map = {}
    for k, v in pairs(default_wrap_map) do symbol_map[k] = v end
    local ok_map, map = pcall(function() return config:get_map("paired_symbols/symkey") end)
    if ok_map and map then
        local ok_keys, keys = pcall(function() return map:keys() end)
        if ok_keys and keys then
            for _, key in ipairs(keys) do
                local ok_val, v = pcall(function() return config:get_string("paired_symbols/symkey/" .. key) end)
                if ok_val and v and #v > 0 then symbol_map[string.lower(key)] = v end
            end
        end
    end
    return symbol_map
end

local function precompile_wrap_parts(wrap_map, delimiter)
    delimiter = delimiter or "|"
    local parts = {}
    for k, wrap_str in pairs(wrap_map) do
        if not wrap_str or wrap_str == "" then
            parts[k] = { l = "", r = "" }
        else
            local pos = find(wrap_str, delimiter, 1, true)
            if pos then
                local left = sub(wrap_str, 1, pos - 1) or ""
                local right = sub(wrap_str, pos + 1) or ""
                parts[k] = { l = left, r = right }
            else
                -- 使用 utf8_codes 避免创建 table
                local first, last
                local count = 0
                for _, cp in utf8_codes(wrap_str) do
                    local char = utf8.char(cp)
                    if count == 0 then first = char end
                    last = char
                    count = count + 1
                end

                if count == 0 then
                    parts[k] = { l = "", r = "" }
                elseif count == 1 then
                    parts[k] = { l = first, r = "" }
                elseif count == 2 then
                    parts[k] = { l = first, r = last } -- 双字时左右各一
                else
                    parts[k] = { l = first, r = last } -- 多字时首尾各一
                end
            end
        end
    end
    return parts
end

-- 检查交集
local function check_intersection(db_attr, config_base_set)
    if not db_attr or db_attr == "" then return false end
    for i = 1, #db_attr do
        local c = sub(db_attr, i, i)
        if config_base_set[c] then
            return true
        end
    end
    return false
end

-- 初始化字符集过滤配置
local function init_charset_filter(env, cfg)
    -- 1. 加载数据库文件
    local dist = (rime_api.get_distribution_code_name() or ""):lower()
    local charsetFile
    if dist == "weasel" then
        charsetFile = "lua/data/charset.reverse.bin"
    else
        charsetFile = wanxiang.get_filename_with_fallback("lua/data/charset.reverse.bin") or "lua/data/charset.reverse.bin"
    end

    env.charset_db = nil
    if ReverseDb then
        local ok, db = pcall(function() return ReverseDb(charsetFile) end)
        if ok and db then env.charset_db = db end
    end
    env.db_memo = {}
    env.filters = {}

    if not cfg then return end

    local root_path = "charset"
    local list = cfg:get_list(root_path)
    if not list then return end

    local list_size = list.size
    for i = 0, list_size - 1 do
        local entry_path = root_path .. "/@" .. i

        -- 解析开关
        local triggers = {}
        local opts_keys = {"option", "options"}
        for _, key in ipairs(opts_keys) do
            local key_path = entry_path .. "/" .. key
            local sub_list = cfg:get_list(key_path)
            if sub_list then
                for k = 0, sub_list.size - 1 do
                    local val = cfg:get_string(key_path .. "/@" .. k)
                    if val and val ~= "" then table.insert(triggers, val) end
                end
            else
                if cfg:get_bool(key_path) == true then
                    table.insert(triggers, "true")
                else
                    local val = cfg:get_string(key_path)
                    if val and val ~= "" and val ~= "true" then
                        table.insert(triggers, val)
                    end
                end
            end
        end

        if #triggers > 0 then
            -- 物理隔离变量
            local rule_base_set = {}
            local rule_add = {}
            local rule_ban = {}

            -- 解析 Base
            local base_str = cfg:get_string(entry_path .. "/base")
            if base_str and #base_str > 0 then
                for j = 1, #base_str do
                    rule_base_set[sub(base_str, j, j)] = true
                end
            end

            -- 解析 Addlist
            local function load_list_to_map(list_name, map)
                local lp = entry_path .. "/" .. list_name
                local sl = cfg:get_list(lp)
                if sl then
                    for k = 0, sl.size - 1 do
                        local val = cfg:get_string(lp .. "/@" .. k)
                        if val and val ~= "" then
                            for _, cp in utf8_codes(val) do map[cp] = true end
                        end
                    end
                end
            end

            load_list_to_map("addlist", rule_add)
            load_list_to_map("blacklist", rule_ban)

            table.insert(env.filters, {
                options  = triggers,
                base_set = rule_base_set,
                add      = rule_add,
                ban      = rule_ban
            })
        end
    end
end

-- 核心判定逻辑
local function codepoint_in_charset(env, ctx, codepoint, text)
    if not env.charset_db then return true end

    local filters = env.filters
    if not filters or #filters == 0 then return true end

    local active_options_count = 0

    for _, rule in ipairs(filters) do
        -- 检查开关
        local is_rule_active = false
        for _, opt_name in ipairs(rule.options) do
            if opt_name == "true" or ctx:get_option(opt_name) then
                is_rule_active = true
                break
            end
        end

        if is_rule_active then
            active_options_count = active_options_count + 1

            -- 1. 黑名单 (最高优先级)
            if rule.ban[codepoint] then
            -- 2. 白名单 (次高优先级)
            elseif rule.add[codepoint] then
                return true -- 显式白名单，直接放行 (Short-circuit)

            -- 3. Base 属性检查
            else
                local attr = env.db_memo[text]
                if attr == nil then
                    attr = env.charset_db:lookup(text)
                    env.db_memo[text] = attr
                end

                if check_intersection(attr, rule.base_set) then
                    return true -- 属性符合，直接放行 (Short-circuit)
                end
            end
        end
    end

    -- 如果没有开启任何规则 -> 显示所有
    if active_options_count == 0 then
        return true
    end

    -- 开启了规则，但没有任何一个规则返回 true -> 隐藏
    return false
end

local function in_charset(env, ctx, text)
    if not text or text == "" then return true end

    local cp_count = 0
    local target_cp = nil
    for _, cp in utf8_codes(text) do
        cp_count = cp_count + 1
        if cp_count > 1 then return true end
        target_cp = cp
    end

    if cp_count == 0 or not target_cp then return true end
    local char = utf8.char(target_cp)

    if not wanxiang.IsChineseCharacter(char) then return true end

    return codepoint_in_charset(env, ctx, target_cp, char)
end

function M.init(env)
    local cfg = env.engine and env.engine.schema and env.engine.schema.config

    env.wrap_map = cfg and load_mapping_from_config(cfg) or default_wrap_map
    env.wrap_delimiter = "|"
    if cfg then
        local d = cfg:get_string("paired_symbols/delimiter")
        if d and #d > 0 then env.wrap_delimiter = d:sub(1,1) end
    end
    env.wrap_parts = precompile_wrap_parts(env.wrap_map, env.wrap_delimiter)

    -- 触发符
    env.symbol = "\\"
    if cfg then
        local sym = cfg:get_string("paired_symbols/symbol") or cfg:get_string("paired_symbols/trigger")
        if sym and #sym > 0 then env.symbol = sub(sym, 1, 1) end
    end

    env.cache = nil; env.locked = false
    -- PageSize & TablePosition
    env.page_size = (cfg and cfg:get_int("menu/page_size"))

    env.table_idx = env.page_size
    if cfg then
        local tp = cfg:get_int("idiom_preposition")
        if tp and tp >= 0 and tp <= env.page_size then
            env.table_idx = tp
        end
    end

    init_charset_filter(env, cfg)
    local schema_id = env.engine.schema.schema_id
    env.enable_taichi_filter = (schema_id == "wanxiang" or schema_id == "wanxiang_pro")
end

function M.fini(env)
    env.charset_db = nil; env.db_memo = nil; env.filters = nil; env.wrap_map = nil; env.wrap_parts = nil
end

-- 上屏管道：负责去重、格式化、修饰
local function emit_with_pipeline(wrapper, ctxs)
    local cand = wrapper.cand
    local text = wrapper.text

    -- 1. 字符集过滤
    if ctxs.charset_active and text ~= "" then
        if not in_charset(ctxs.env, ctxs.ctx, text) then return false end
    end

    -- 2. 太极/句子过滤 (使用缓存的属性)
    if ctxs.enable_taichi_filter and wrapper.has_eng then
        if cand.comment and find(cand.comment, "\226\152\175") then return false end
    end

    -- 3. 英文长句过滤 (Function E)
    if ctxs.drop_sentence_after_completion then
        if cand.type == "sentence" then return false end
    end

    -- 4. 最终去重
    if ctxs.suppress_set and ctxs.suppress_set[text] then return false end

    -- 5. 格式化与修饰
    cand = format_and_autocap(cand)
    cand = ctxs.unify_tail_span(cand)

    yield(cand)
    return true
end

function M.func(input, env)
    local ctx  = env and env.engine and env.engine.context or nil
    local code = ctx and (ctx.input or "") or ""
    local comp = ctx and ctx.composition or nil

    -- 1. 快速环境检查
    if not code or code == "" or (comp and comp:empty()) then
        env.cache, env.locked = nil, false
    end

    -- 2. 状态缓存
    local is_functional = false
    if ctx and wanxiang and wanxiang.s2t_conversion then
        is_functional = wanxiang.s2t_conversion(ctx)
    end
    local charset_active = (env.filters and #env.filters > 0) and (not is_functional)
    -- 五码且最后一个字符是 '/' 时禁用字符集过滤
    if #code == 5 and code:sub(-1):find("[^%w]") then
        charset_active = false
    end

    local enable_taichi = env.enable_taichi_filter

    -- 3. 符号与分段分析
    local symbol = env.symbol
    local code_has_symbol = symbol and #symbol == 1 and (find(code, symbol, 1, true) ~= nil)
    local fully_consumed, last_seg, wrap_key, keep_tail_len = false, nil, nil, 0

    if code_has_symbol then
        last_seg = comp and comp:back()
        local segm = comp and comp:toSegmentation()
        local confirmed = segm and segm.get_confirmed_position and segm:get_confirmed_position() or 0
        local code_len = #code

        if last_seg and last_seg.start and last_seg._end then
            fully_consumed = (last_seg.start == confirmed) and (last_seg._end == code_len)
            if fully_consumed then
                local last_text = sub(code, last_seg.start + 1, last_seg._end)
                local pos = find(last_text, symbol, 1, true)
                if pos and pos > 1 then
                    env.locked = true
                    local right = sub(last_text, pos + 1)
                    keep_tail_len = 1 + #right
                    local k = right:lower()
                    if k ~= "" and env.wrap_map[k] then wrap_key = k end
                end
            end
        end
    else
        env.locked = false
    end

    local code_len = #code
    local do_group = (env.table_idx > 0) and (code_len >= 2 and code_len <= 6)

    -- 闭包上下文 (Context)
    local function unify_tail_span(c)
        if fully_consumed and wrap_key and last_seg and c and c._end ~= last_seg._end then
            local nc = Candidate(c.type, c.start, last_seg._end, c.text, c.comment)
            nc.preedit = c.preedit; return nc
        end
        return c
    end

    local emit_ctx = {
        env = env, ctx = ctx, suppress_set = nil,
        unify_tail_span = unify_tail_span, charset_active = charset_active,
        enable_taichi_filter = enable_taichi,
        drop_sentence_after_completion = false -- 初始化为 false
    }

    -- 4. 加壳逻辑 (Wrap Logic)
    local function wrap_from_base(wrapper, key)
        if not wrapper or not key then return nil end
        local base_text = wrapper.text
        if emit_ctx.suppress_set and emit_ctx.suppress_set[base_text] then return nil end

        local pair = env.wrap_map[key]; if not pair then return nil end
        local formatted = format_and_autocap(wrapper.cand)
        local pr = env.wrap_parts[key] or { l = "", r = "" }
        local wrapped_text = (pr.l or "") .. (formatted.text or "") .. (pr.r or "")

        local start_pos = (last_seg and last_seg.start) or formatted.start or 0
        local end_pos   = (last_seg and last_seg._end)  or (start_pos + code_len)

        local nc = Candidate(formatted.type, start_pos, end_pos, wrapped_text, formatted.comment)
        nc.preedit = formatted.preedit

        return {
            cand = nc, text = wrapped_text,
            is_table = wrapper.is_table, has_eng = wrapper.has_eng
        }, base_text
    end

    local page_size = env.page_size
    local target_idx = env.table_idx
    local sort_window = 30
    local wrap_limit = page_size * 2
    local visual_idx = 0

    -- 通用候选处理 (Wrap -> Emit)
    local function try_process_wrapper(wrapper)
        local final_wrapper = wrapper
        -- 尝试加壳
        if wrap_key and visual_idx < wrap_limit then
            if emit_ctx.suppress_set and emit_ctx.suppress_set[wrapper.text] then
                final_wrapper = wrapper -- 原词已出，不加壳
            else
                local wrapped_w, base_txt = wrap_from_base(wrapper, wrap_key)
                if wrapped_w then
                    if not emit_ctx.suppress_set then emit_ctx.suppress_set = {} end
                    emit_ctx.suppress_set[base_txt] = true
                    final_wrapper = wrapped_w
                end
            end
        end

        if emit_with_pipeline(final_wrapper, emit_ctx) then
            visual_idx = visual_idx + 1
            return true
        end
        return false
    end

    -- 模式 1: 非分组 (Direct Pass)
    if not do_group then
        local idx = 0
        for cand in input:iter() do
            idx = idx + 1
            -- 封装 Wrapper，后续逻辑复用属性
            local txt = cand.text
            local w = {
                cand = cand,
                text = txt,
                is_table = is_table_type(cand),
                has_eng = has_english_token_fast(txt)
            }

            if idx == 1 then
                -- 英文长句过滤触发器
                if w.is_table and #txt >= 4 and w.has_eng then
                    emit_ctx.drop_sentence_after_completion = true
                end

                -- 符号出现时，保护 Cache 不被覆盖
                if not code_has_symbol then
                    env.cache = clone_candidate(format_and_autocap(cand))
                end

                -- Locked state: emit cache
                if env.locked and (not wrap_key) and env.cache then
                    local base = format_and_autocap(env.cache)
                    local start_pos = (last_seg and last_seg.start) or 0
                    local end_pos   = (last_seg and last_seg._end) or code_len
                    if keep_tail_len > 0 then end_pos = math.max(start_pos, end_pos - keep_tail_len) end

                    local nc = Candidate(base.type, start_pos, end_pos, base.text, base.comment)
                    nc.preedit = base.preedit

                    if emit_with_pipeline({cand=nc, text=base.text, has_eng=w.has_eng}, emit_ctx) then
                        visual_idx = visual_idx + 1
                    end
                    goto continue_loop
                end

                -- Wrap first cand
                if wrap_key and env.cache then
                    local cache_w = {cand=env.cache, text=env.cache.text, is_table=w.is_table, has_eng=w.has_eng}
                    local wrapped_w, base_txt = wrap_from_base(cache_w, wrap_key)
                    if wrapped_w then
                        if not emit_ctx.suppress_set then emit_ctx.suppress_set = {} end
                        emit_ctx.suppress_set[base_txt] = true
                        if emit_with_pipeline(wrapped_w, emit_ctx) then
                            visual_idx = visual_idx + 1
                            goto continue_loop
                        end
                    end
                end
            end

            try_process_wrapper(w)
            ::continue_loop::
        end
        return
    end

    -- 模式 2: 分组模式 (Grouping)
    local idx2 = 0
    local mode = "unknown" -- unknown | passthrough | grouping

    local normal_buf = {}   -- 存 Normal
    local special_buf = {}  -- 存 Table/UserTable

    local function try_flush_page_sort(force_all)
        while true do
            local next_pos = visual_idx + 1
            local current_idx_in_page = ((next_pos - 1) % page_size) + 1
            local is_second_page = (visual_idx >= page_size)

            local allow_special = is_second_page or (current_idx_in_page >= target_idx)

            local w_to_emit = nil
            if force_all then
                if allow_special then
                    if #special_buf > 0 then w_to_emit = table.remove(special_buf, 1)
                    elseif #normal_buf > 0 then w_to_emit = table.remove(normal_buf, 1) end
                else
                    if #normal_buf > 0 then w_to_emit = table.remove(normal_buf, 1)
                    elseif #special_buf > 0 then w_to_emit = table.remove(special_buf, 1) end
                end
                if not w_to_emit then break end
            else
                if allow_special then
                    if #special_buf > 0 then
                        w_to_emit = table.remove(special_buf, 1)
                    else
                        if #normal_buf > sort_window then
                            w_to_emit = table.remove(normal_buf, 1)
                        else
                            break
                        end
                    end
                else
                    if #normal_buf > 0 then
                        w_to_emit = table.remove(normal_buf, 1)
                    else
                        break
                    end
                end
            end

            if w_to_emit then
                try_process_wrapper(w_to_emit)
            end
        end
    end

    local grouped_cnt = 0
    local window_closed = false

    for cand in input:iter() do
        idx2 = idx2 + 1
        local txt = cand.text
        local w = {
            cand = cand,
            text = txt,
            is_table = is_table_type(cand),
            has_eng = has_english_token_fast(txt)
        }

        if idx2 == 1 then
             if not env.locked then env.cache = clone_candidate(format_and_autocap(cand)) end
             if w.is_table and #txt >= 4 and w.has_eng then
                 emit_ctx.drop_sentence_after_completion = true
             end

             local emitted = false
             if env.locked and (not wrap_key) and env.cache then
                local base = format_and_autocap(env.cache)
                local start_pos = (last_seg and last_seg.start) or 0
                local end_pos   = (last_seg and last_seg._end) or code_len
                if keep_tail_len > 0 then end_pos = math.max(start_pos, end_pos - keep_tail_len) end
                local nc = Candidate(base.type, start_pos, end_pos, base.text, base.comment)
                nc.preedit = base.preedit
                if emit_with_pipeline({cand=nc, text=base.text, has_eng=w.has_eng}, emit_ctx) then
                    visual_idx = visual_idx + 1; emitted = true
                end
             elseif wrap_key then
                 local cache_w = {cand=env.cache or cand, text=(env.cache or cand).text, is_table=w.is_table, has_eng=w.has_eng}
                 local wrapped_w, base_txt = wrap_from_base(cache_w, wrap_key)
                 if wrapped_w then
                     if not emit_ctx.suppress_set then emit_ctx.suppress_set = {} end
                     emit_ctx.suppress_set[base_txt] = true
                     if emit_with_pipeline(wrapped_w, emit_ctx) then visual_idx = visual_idx + 1; emitted = true end
                 end
             end
             if not emitted then try_process_wrapper(w) end

        elseif idx2 == 2 and mode == "unknown" then
            if w.is_table then
                mode = "passthrough"
                try_process_wrapper(w)
            else
                mode = "grouping"
                table.insert(normal_buf, w)
                try_flush_page_sort(false)
            end

        else
            if mode == "passthrough" then
                try_process_wrapper(w)
            else
                if (not window_closed) and (grouped_cnt < sort_window) then
                    grouped_cnt = grouped_cnt + 1
                    if w.is_table and (not w.has_eng) then
                        table.insert(special_buf, w)
                    else
                        table.insert(normal_buf, w)
                    end

                    if grouped_cnt >= sort_window then window_closed = true end
                    try_flush_page_sort(false)
                else
                    if w.is_table and (not w.has_eng) then
                        table.insert(special_buf, w)
                    else
                        table.insert(normal_buf, w)
                    end
                    try_flush_page_sort(false)
                end
            end
        end
    end

    if mode == "grouping" then
        try_flush_page_sort(true)
    end
end
return M