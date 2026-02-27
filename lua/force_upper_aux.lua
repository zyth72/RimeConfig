-- lua/force_upper_aux.lua
-- @description: 自动将N-1首选数量的汉字大写辅助码施加到音节后面，支持【当前/最早历史】双态切换
-- @author: amzxyz

local ForceUpperAux = {}

-- 获取 UTF-8 字符
local function get_utf8_char(str, index)
    local start_byte = utf8.offset(str, index)
    if not start_byte then return nil end
    local end_byte = utf8.offset(str, index + 1)
    return string.sub(str, start_byte, (end_byte and end_byte - 1) or nil)
end

-- 获取 UTF-8 前缀
local function get_utf8_prefix(str, n)
    if not str or str == "" or n <= 0 then return "" end
    local offset = utf8.offset(str, n + 1)
    return offset and string.sub(str, 1, offset - 1) or str
end

-- 获取分隔符
local function get_delimiters(ctx)
    local cfg = ctx.engine and ctx.engine.schema and ctx.engine.schema.config
    local delimiter = (cfg and cfg:get_string("speller/delimiter")) or " '"
    return delimiter:sub(1, 1), delimiter:sub(2, 2)
end

-- 转义正则符号
local function esc_class(c)
    return (c:gsub("([%%%^%]%-])", "%%%1"))
end
-- 获取有效的反查词典 (优先 wanxiang_pro, 其次 wanxiang，且需包含分号)
local function load_valid_dict()
    local dicts_to_try = {"wanxiang_pro", "wanxiang"}
    local test_char = "我"
    
    for _, name in ipairs(dicts_to_try) do
        local dict = ReverseLookup(name)
        if dict then
            local res = dict:lookup(test_char)
            if res and string.find(res, ";") then
                return dict
            end
        end
    end
    return ReverseLookup("wanxiang_pro")
end
-- 获取输入切分后的拼音部分
local function get_script_text_parts(ctx)
    local raw_in    = ctx.input or ""
    local prop_key  = ctx:get_property("sequence_preedit_key") or ""
    local prop_val  = ctx:get_property("sequence_preedit_val") or ""
    local script_txt = ctx:get_script_text() or ""

    local s = (prop_key == raw_in and prop_val ~= "") and prop_val or script_txt
    if s == "" then return {} end

    local auto, manual = get_delimiters(ctx)
    local pat = "[^" .. esc_class(auto) .. esc_class(manual) .. "%s]+"
    local parts = {}
    for w in s:gmatch(pat) do parts[#parts + 1] = w end
    return parts
end

-- 查询辅助码
local function lookup_aux_code(env, char)
    if env.aux_cache[char] then return env.aux_cache[char] end
    
    local raw_code = env.dict:lookup(char)
    if not raw_code or raw_code == "" then return "" end
    
    local aux_part = raw_code:match(";([^,]+)") or raw_code:match("^([^;]+)") or ""
    local final_code = aux_part:gsub("[^a-zA-Z]", ""):sub(1, 2):upper()
    
    env.aux_cache[char] = final_code
    return final_code
end

-- 初始化
function ForceUpperAux.init(env)
    local config = env.engine.schema.config
    env.trigger_key = config:get_string("force_upper_aux/hotkey") or "Tab"

    env.aux_cache = {}
    env.dict = load_valid_dict()
    
    -- 双态切换核心变量
    env.history_first = {}           -- 记录每个长度【最早出现】的候选词
    env.press_count = 0              -- 按键次数（奇数=当前，偶数=最早历史）
    env.is_cycling = false           -- 状态机锁定标识，防止快照被污染
    env.snapshot_parts = nil         -- 首次按键时的拼音切分快照
    env.snapshot_current_prefix = "" -- 首次按键时的【当前】N-1候选快照
    
    env.on_update = function(ctx)
        -- 快捷键循环期间，冻结历史更新
        if env.is_cycling then return end
        
        if not ctx:is_composing() then
            env.history_first = {}
            env.press_count = 0
            env.is_cycling = false
            env.snapshot_parts = nil
            env.snapshot_current_prefix = ""
            return
        end
        
        local parts = get_script_text_parts(ctx)
        local parts_count = #parts
        if parts_count == 0 then return end
        
        local comp = ctx.composition
        if not comp:empty() then
            local segment = comp:back()
            local cand = segment:get_candidate_at(0)
            
            if cand and cand.text then
                local prefix = get_utf8_prefix(cand.text, parts_count)
                -- 核心：仅记录首次达到该长度的词条，锁定“最早历史”
                if not env.history_first[parts_count] then
                    env.history_first[parts_count] = prefix
                end
            end
        end
    end
    
    env.update_conn = env.engine.context.update_notifier:connect(env.on_update)
end

function ForceUpperAux.fini(env)
    if env.update_conn then
        env.update_conn:disconnect()
    end
end

-- 核心按键处理逻辑
function ForceUpperAux.func(key_event, env)
    if key_event:release() then return 2 end
    local current_key = key_event:repr()
    
    if current_key == env.trigger_key then
        local ctx = env.engine.context
        if not ctx:is_composing() then return 2 end
        
        env.update_conn:disconnect()
        
        -- 首次按下：生成干净的现场快照
        if env.press_count == 0 then
            env.snapshot_parts = get_script_text_parts(ctx)
            
            local p_count = #(env.snapshot_parts)
            local target_len = p_count > 1 and (p_count - 1) or 1
            
            -- 提取触发那一刻的“当前”候选
            local comp = ctx.composition
            if not comp:empty() then
                local cand = comp:back():get_candidate_at(0)
                if cand then
                    env.snapshot_current_prefix = get_utf8_prefix(cand.text, target_len)
                end
            end
        end
        
        local parts = env.snapshot_parts
        if not parts or #parts == 0 then
            env.update_conn = ctx.update_notifier:connect(env.on_update)
            return 2 
        end
        
        env.press_count = env.press_count + 1
        env.is_cycling = true 
        
        local parts_count = #parts
        local target_len = parts_count > 1 and (parts_count - 1) or 1
        local candidate_text = ""
        
        -- 双态切换：奇数次取【当前快照】，偶数次取【最早历史】
        if env.press_count % 2 == 1 then
            candidate_text = env.snapshot_current_prefix
        else
            candidate_text = env.history_first[target_len] or env.snapshot_current_prefix
        end
        
        -- 生成包含辅助码的新输入串
        local new_input = ""
        local text_len = utf8.len(candidate_text) or 0
        for i = 1, parts_count do
            local syl = parts[i]
            if i <= text_len and i < parts_count then
                local pinyin = syl:sub(1, 2)
                local char = get_utf8_char(candidate_text, i)
                local aux = lookup_aux_code(env, char)
                new_input = new_input .. pinyin .. aux
            else
                new_input = new_input .. syl
            end
        end
        
        -- 替换并刷新输入
        if new_input ~= "" and new_input ~= ctx.input then
            ctx.input = new_input
        end
        
        env.update_conn = ctx.update_notifier:connect(env.on_update)
        return 1 -- kAccepted
    else
        -- 任意其他按键打断循环，重置状态机
        env.press_count = 0
        env.is_cycling = false
        env.snapshot_parts = nil
        env.snapshot_current_prefix = ""
        return 2 -- kNoop
    end
end

return ForceUpperAux