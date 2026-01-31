--[[
super_replacer.lua 一个rime OpenCC替代品，更灵活地配置能力
https://github.com/amzxyz/rime_wanxiang
by amzxyz
路径检测：UserDir > SharedDir
支持 option: true (常驻启用)
super_replacer:
    db_name: lua/replacer
    delimiter: "|"
    comment_format: "〔%s〕"
    chain: true   #true表示流水线作业，上一个option产出交给下一个处理，典型的s2t>t2hk=s2hk，false就是并行，直接用text转换
    types:
      # 场景1：输入 '哈哈' -> 变成 '1.哈哈 2.😄'
      - option: emoji           # 开关名称与上面开关名称保持一致
        mode: append            # 新增候选append 替换原候选replace 替换注释comment
        comment_mode: none      # 注释模式: "append"(原候选注释继承), "text"(原候选文本放在注释), "none"(空，默认)
        tags: [abc]             # 生效的tag
        prefix: "_em_"          # 前缀用于区分同一个数据库的不同用途数据
        files:
          - lua/data/emoji.txt
      # 场景2：输入 'hello' -> 显示 'hello 〔你好 | 哈喽〕'
      - option: chinese_english
        mode: append        # <--- 添加注释模式
        comment_mode: none
        tags: [abc]
        prefix: "_en_"
        files:
          - lua/data/english_chinese.txt
          - lua/data/chinese_english.txt
      # 场景3：用于常驻的直接替换 option: true
      - option: true
        mode: append         # <--- 新增候选模式
        comment_mode: none
        tags: [abc]
        prefix: "_ot_"
        files:
          - lua/data/others.txt
      # 场景4：用于简繁转换的直接替换
      - option: [ s2t, s2hk, s2tw ]   #后面依赖这条流水线有一个开关为true这条流水线就能工作
        mode: replace         # <--- 替换原候选模式
        comment_mode: append
        sentence: true        # <--- 句子级别替换
        tags: [abc]
        prefix: "_s2t_"
        files:
          - lua/data/STCharacters.txt
          - lua/data/STPhrases.txt
      - option: s2hk
        mode: replace         # <--- 替换原候选模式
        comment_mode: append
        sentence: true        # <--- 句子级别替换
        tags: [abc]
        prefix: "_s2hk_"
        files:
          - lua/data/HKVariants.txt
          - lua/data/HKVariantsRevPhrases.txt
      - option: s2tw
        mode: replace         # <--- 替换原候选模式
        comment_mode: append
        sentence: true        # <--- 句子级别替换
        tags: [abc]
        prefix: "_s2tw_"
        files:
          - lua/data/TWVariants.txt
          - lua/data/TWVariantsRevPhrases.txt
      - option: [ abbrev_lazy, abbrev_always ] 
        mode: abbrev          # <--- 新增的简码模式
        tags: [abc]
        prefix: "_abbr_"
        files:
          - lua/data/abbrev.txt # 格式：zm\t怎么|在吗
]]

local M = {}

-- 性能优化：本地化常用库函数
local insert = table.insert
local concat = table.concat
local s_match = string.match
local s_gmatch = string.gmatch
local s_format = string.format
local s_byte = string.byte
local s_sub = string.sub
local s_gsub = string.gsub
local s_upper = string.upper
local open = io.open
local type = type
local tonumber = tonumber

-- 基础依赖
local function safe_require(name)
    local status, lib = pcall(require, name)
    if status then return lib end
    return nil
end

local userdb = safe_require("lib/userdb") or safe_require("userdb")
local wanxiang = safe_require("wanxiang")

-- 重建数据库 (仅在 wanxiang 版本变更时运行)
local function rebuild(tasks, db)
    if db.empty then db:empty() end
    for _, task in ipairs(tasks) do
        local txt_path = task.path
        local prefix = task.prefix
        local f = open(txt_path, "r")
        if f then
            for line in f:lines() do
                if line ~= "" and not s_match(line, "^%s*#") then
                    local k, v = s_match(line, "^(%S+)%s+(.+)")
                    if k and v then
                        v = s_match(v, "^%s*(.-)%s*$")
                        db:update(prefix .. k, v)
                    end
                end
            end
            f:close()
        else
            if log and log.info then log.info("super_replacer: 无法读取文件: " .. txt_path) end
        end
    end
    return true
end

-- UTF-8 辅助
local function get_utf8_offsets(text)
    local offsets = {}
    local len = #text
    local i = 1
    while i <= len do
        insert(offsets, i)
        local b = s_byte(text, i)
        if b < 128 then i = i + 1
        elseif b < 224 then i = i + 2
        elseif b < 240 then i = i + 3
        else i = i + 4 end
    end
    insert(offsets, len + 1)
    return offsets
end

-- FMM 分词转换算法
local function segment_convert(text, db, prefix, split_pat)
    local offsets = get_utf8_offsets(text)
    local char_count = #offsets - 1
    local result_parts = {}
    local i = 1 
    local MAX_LOOKAHEAD = 6 
    
    while i <= char_count do
        local matched = false
        local max_j = i + MAX_LOOKAHEAD
        if max_j > char_count + 1 then max_j = char_count + 1 end
        
        for j = max_j - 1, i + 1, -1 do
            local start_byte = offsets[i]
            local end_byte = offsets[j] - 1
            local sub_text = s_sub(text, start_byte, end_byte)
            
            local val = db:fetch(prefix .. sub_text)
            if val then
                local first_val = s_match(val, split_pat) 
                insert(result_parts, first_val or sub_text)
                i = j - 1 
                matched = true
                break
            end
        end
        
        if not matched then
            local start_byte = offsets[i]
            local end_byte = offsets[i+1] - 1
            local char = s_sub(text, start_byte, end_byte)
            local val = db:fetch(prefix .. char)
            if val then
                local first_val = s_match(val, split_pat)
                insert(result_parts, first_val or char)
            else
                insert(result_parts, char)
            end
        end
        i = i + 1
    end
    return concat(result_parts)
end

-- 模块接口

function M.init(env)
    local ns = env.name_space
    ns = s_gsub(ns, "^%*", "")
    local config = env.engine.schema.config
    
    local user_dir = rime_api:get_user_data_dir()
    local shared_dir = rime_api:get_shared_data_dir()

    -- 1. 基础配置
    local db_name = config:get_string(ns .. "/db_name") or "lua/replacer"
    local delim = config:get_string(ns .. "/delimiter") or "|"
    env.delimiter = delim
    env.comment_format = config:get_string(ns .. "/comment_format") or "〔%s〕"
    
    -- 获取全局版本号
    local current_version = "v0.0.0"
    if wanxiang and wanxiang.version then
        current_version = wanxiang.version
    end
    
    env.chain = config:get_bool(ns .. "/chain")
    if env.chain == nil then env.chain = false end

    if delim == " " then env.split_pattern = "%S+"
    else local esc = s_gsub(delim, "[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1"); env.split_pattern = "([^" .. esc .. "]+)" end

    -- 2. 解析 Types
    env.types = {}
    local tasks = {} -- 仅在需要重建时使用

    local function resolve_path(relative)
        if not relative then return nil end
        local user_path = user_dir .. "/" .. relative
        local f = open(user_path, "r")
        if f then f:close(); return user_path end
        local shared_path = shared_dir .. "/" .. relative
        f = open(shared_path, "r")
        if f then f:close(); return shared_path end
        return user_path
    end

    local types_path = ns .. "/types"
    local type_list = config:get_list(types_path)
    
    if type_list then
        for i = 0, type_list.size - 1 do
            local entry_path = types_path .. "/@" .. i
            
            -- 解析 triggers
            local triggers = {}
            local opts_keys = {"option", "options"}
            for _, key in ipairs(opts_keys) do
                local key_path = entry_path .. "/" .. key
                local list = config:get_list(key_path)
                if list then
                    for k = 0, list.size - 1 do
                        local val = config:get_string(key_path .. "/@" .. k)
                        if val then insert(triggers, val) end
                    end
                else
                    -- 1. 如果配置写的是 true (bool)，get_bool 返回 true，我们插入布尔值 true。
                    -- 2. 如果配置写的是 s2t (string)，get_bool 返回 false (或nil)，我们进入 else 读字符串。
                    if config:get_bool(key_path) == true then 
                        insert(triggers, true) 
                    else
                        local val = config:get_string(key_path)
                        -- 只有当它不是 "true" 字符串时才插入，防止双重解析（虽然上面的if已经拦截了）
                        if val and val ~= "true" then
                            insert(triggers, val)
                        end
                    end
                end
            end

            -- 解析 Tags
            local target_tags = nil
            local tag_keys = {"tag", "tags"}
            for _, key in ipairs(tag_keys) do
                local key_path = entry_path .. "/" .. key
                local list = config:get_list(key_path)
                if list then
                    if not target_tags then target_tags = {} end
                    for k = 0, list.size - 1 do
                        local val = config:get_string(key_path .. "/@" .. k)
                        if val then target_tags[val] = true end
                    end
                else
                    local val = config:get_string(key_path)
                    if val then 
                        if not target_tags then target_tags = {} end
                        target_tags[val] = true 
                    end
                end
            end

            if #triggers > 0 then
                local prefix = config:get_string(entry_path .. "/prefix") or ""
                local mode = config:get_string(entry_path .. "/mode") or "append"
                local comment_mode = config:get_string(entry_path .. "/comment_mode")
                if not comment_mode then comment_mode = "comment" end
                local fmm = config:get_bool(entry_path .. "/sentence")
                if fmm == nil then fmm = false end

                insert(env.types, {
                    triggers = triggers,
                    tags = target_tags,
                    prefix = prefix,
                    mode   = mode,
                    comment_mode = comment_mode,
                    fmm = fmm
                })

                -- 收集文件路径 (用于重建)
                local keys_to_check = {"files", "file"}
                for _, key in ipairs(keys_to_check) do
                    local d_path = entry_path .. "/" .. key
                    local list = config:get_list(d_path)
                    if list then
                        for j = 0, list.size - 1 do
                            local p = resolve_path(config:get_string(d_path .. "/@" .. j))
                            if p then insert(tasks, { path = p, prefix = prefix }) end
                        end
                    else
                        local p = resolve_path(config:get_string(d_path))
                        if p then insert(tasks, { path = p, prefix = prefix }) end
                    end
                end
            end
        end
    end

    -- 3. DB 初始化
    if not userdb then return end
    local ok, db = pcall(function() local d = userdb.LevelDb(db_name); d:open(); return d end)

    if ok and db then
        env.db = db
        local db_version = db:meta_fetch("_wanxiang_ver") or ""
        local old_delim = db:meta_fetch("_delim")
        local need_rebuild = false
        if current_version ~= db_version then need_rebuild = true end
        if env.delimiter ~= old_delim then need_rebuild = true end
        
        if need_rebuild then
            if rebuild(tasks, db) then
                db:meta_update("_wanxiang_ver", current_version)
                db:meta_update("_delim", env.delimiter)
                if log and log.info then 
                    log.info("super_replacer: 检测到版本变更 (" .. db_version .. " -> " .. current_version .. ")，数据已重建。") 
                end
            end
        end
    else
        env.db = nil
    end
end

function M.fini(env)
    if env.db then env.db:close(); env.db = nil end
end

-- [Core Function] 核心逻辑
function M.func(input, env)
    if not env.types or #env.types == 0 or not env.db then
        for cand in input:iter() do yield(cand) end
        return
    end

    local ctx = env.engine.context
    local db = env.db
    local types = env.types
    local split_pat = env.split_pattern
    local comment_fmt = env.comment_format
    local is_chain = env.chain
    local input_code = ctx.input

    local input_type = "unknown"
    if wanxiang and wanxiang.get_input_method_type then
        input_type = wanxiang.get_input_method_type(env)
    end

    local seg = ctx.composition:back()
    local current_seg_tags = seg and seg.tags or {}
    -- [Helper] 通用处理函数
    local function process_rules(cand)
        local current_text = cand.text
        local show_main = true 
        local current_main_comment = cand.comment 
        
        local pending_candidates = {} 
        local comments = {}
        
        for _, t in ipairs(types) do
            if t.mode ~= "abbrev" then -- 跳过 abbrev 模式
                local is_active = false
                for _, trigger in ipairs(t.triggers) do
                    if trigger == true then is_active = true; break
                    elseif type(trigger) == "string" and ctx:get_option(trigger) then is_active = true; break end
                end
                
                local is_tag_match = true
                if t.tags then
                    is_tag_match = false
                    for req_tag, _ in pairs(t.tags) do
                        if current_seg_tags[req_tag] then is_tag_match = true; break end
                    end
                end
                
                if is_active and is_tag_match then
                    local query_text = is_chain and current_text or cand.text
                    local key = t.prefix .. query_text
                    local val = db:fetch(key)
                    
                    if not val and t.fmm then
                        local seg_result = segment_convert(query_text, db, t.prefix, split_pat)
                        if seg_result ~= query_text then val = seg_result end
                    end
                    
                    if val then
                        local mode = t.mode
                        local rule_comment = ""
                        if t.comment_mode == "text" then rule_comment = cand.text
                        elseif t.comment_mode == "comment" then rule_comment = cand.comment end

                        if mode == "comment" then
                            local parts = {}
                            for p in s_gmatch(val, split_pat) do insert(parts, p) end
                            insert(comments, concat(parts, " "))
                            
                        elseif mode == "replace" then
                            if is_chain then
                                local first = true
                                for p in s_gmatch(val, split_pat) do
                                    if first then 
                                        current_text = p
                                        if t.comment_mode == "none" then current_main_comment = ""
                                        elseif t.comment_mode == "text" then current_main_comment = cand.text end
                                        first = false
                                    else
                                        insert(pending_candidates, { text=p, comment=rule_comment })
                                    end
                                end
                            else
                                show_main = false
                                for p in s_gmatch(val, split_pat) do 
                                    insert(pending_candidates, { text=p, comment=rule_comment }) 
                                end
                            end
                        elseif mode == "append" then
                            for p in s_gmatch(val, split_pat) do 
                                insert(pending_candidates, { text=p, comment=rule_comment }) 
                            end
                        end
                    end
                end
            end 
        end

        if #comments > 0 then
            local comment_str = concat(comments, " ")
            local fmt = s_format(comment_fmt, comment_str)
            if cand.comment and cand.comment ~= "" then
                cand.comment = cand.comment .. fmt
            else
                cand.comment = fmt
            end
        end

        if show_main then
            if is_chain and current_text ~= cand.text then
                local nc = Candidate(cand.type or "kv", cand.start, cand._end, current_text, current_main_comment)
                nc.preedit = cand.preedit 
                nc.quality = cand.quality
                yield(nc)
            else
                yield(cand)
            end
        end

        for _, item in ipairs(pending_candidates) do
            if not (show_main and item.text == current_text) then
                local nc = Candidate("derived", cand.start, cand._end, item.text, item.comment)
                nc.preedit = cand.preedit
                nc.quality = cand.quality 
                yield(nc)
            end
        end
    end
    -- [Helper] 尝试触发简码
    local function try_trigger_abbrev(is_empty_override)
        for _, t in ipairs(types) do
            -- 只有当模式是 abbrev 且 当前不是全拼 时，才进入逻辑
            if t.mode == "abbrev" and input_type ~= "pinyin" then
                local is_tag_match = true
                if t.tags then
                    is_tag_match = false
                    for req_tag, _ in pairs(t.tags) do
                        if current_seg_tags[req_tag] then is_tag_match = true; break end
                    end
                end

                if is_tag_match then
                    local lazy_switch = t.triggers[1]
                    local always_switch = t.triggers[2]
                    local active_mode = "none"

                    if always_switch then
                        if always_switch == true or (type(always_switch) == "string" and ctx:get_option(always_switch)) then
                            active_mode = "always"
                        end
                    end
                    if active_mode == "none" and lazy_switch then
                        if lazy_switch == true or (type(lazy_switch) == "string" and ctx:get_option(lazy_switch)) then
                            active_mode = "lazy"
                        end
                    end

                    local should_trigger = false
                    if active_mode == "always" then should_trigger = true
                    elseif active_mode == "lazy" and is_empty_override then should_trigger = true
                    end

                    if should_trigger then
                         -- ... (查库逻辑) ...
                        local key = t.prefix .. input_code
                        local val = db:fetch(key)
                        if not val and not s_match(input_code, "[A-Z]") then
                            val = db:fetch(t.prefix .. s_upper(input_code))
                        end
                        if val then
                            for p in s_gmatch(val, split_pat) do
                                local abbrev_cand = Candidate("abbrev", 0, #input_code, p, "")
                                abbrev_cand.quality = 9999
                                process_rules(abbrev_cand)
                            end
                        end
                    end
                end
            end
        end
    end
    -- [Main Loop] 主循环
    local pending_cands = {}
    local limit = 10
    local has_phrase = false
    local cand_count = 0

    for cand in input:iter() do
        cand_count = cand_count + 1
        
        if cand_count <= limit then
            table.insert(pending_cands, cand)
            if cand.type == "phrase" then
                has_phrase = true
            end
        else
            if cand_count == limit + 1 then
                if not has_phrase then 
                    try_trigger_abbrev(true) 
                end
                for _, pc in ipairs(pending_cands) do
                    process_rules(pc)
                end
                pending_cands = nil
            end
            process_rules(cand)
        end
    end

    if pending_cands then
        if not has_phrase then
             try_trigger_abbrev(true)
        end
        for _, pc in ipairs(pending_cands) do
            process_rules(pc)
        end
    end
end
return M