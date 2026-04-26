-- stop-after-current.lua
-- 播放完当前文件后自动停止，不再播放下一个
-- 按大写 P 键开关此功能（默认开启）
--
-- ⚠ GUI 播放按钮支持需要配合修改 osc.lua（见文件修改清单）
--   只复制本文件到另一台电脑时，Space 键可用，GUI 按钮需要打补丁

----------------------------------------------------------------------
-- 设计心得 & mpv Lua 编程注意事项
----------------------------------------------------------------------
--
-- 【本次踩过的坑】
--
-- 1. keep-open 的三个值含义不同（最关键的坑）：
--    "no"     — 文件播完自动播放下一个（默认）
--    "yes"    — 仅在播放列表【最后一个文件】播完时暂停
--    "always" — 每个文件播完都暂停，阻止自动前进
--    → 要实现"播完当前就停"，必须用 "always"，不是 "yes"
--
-- 2. end-file 事件有时序竞争：
--    mpv 在文件到达 EOF 时，内部流程是：
--      ① 决定前进到下一个播放列表条目
--      ② 开始加载下一个文件
--      ③ 触发当前文件的 end-file 事件
--      ④ 触发下一个文件的 start-file 事件
--    → 在 end-file 回调里 set pause 可能暂停的是【下一个文件】
--    → 用 keep-open 属性则从解码器层面阻止前进，零时序风险
--
-- 3. eof-reached 属性的行为：
--    - keep-open=always 下，eof-reached 在 EOF 后【持续为 yes】，不是瞬态的
--    - pause 也会被 keep-open 自动设为 yes
--    - 可以直接在按键处理中读取 eof-reached 判断是否在 EOF 状态
--
-- 4. EOF 时 cycle pause 的实际行为：
--    - mpv 源码中 set_pause_state() 确实不检查 EOF，会切换 pause 值
--    - 但 mpv playloop 中 handle_keep_open() 会在下一个循环立刻重新暂停
--    - 导致 pause 从 yes→no→yes 变化太快，observe_property 无法有效拦截
--    - 必须 seek 0 absolute 重置播放位置，再 set pause=no
--    - 这是 ModernZ、modernx 等生产级 OSC 脚本使用的方案
--
-- 5. GUI 播放按钮无法从外部拦截（最重要的架构约束）：
--    - 键盘 Space → add_forced_key_binding 可拦截 ✅
--    - GUI 播放按钮 → osc.lua 内部 cycle pause，无法从外部拦截 ❌
--    - observe_property("pause") 尝试过，不工作：
--      cycle pause 在 EOF 时短暂切换 pause=no，但 mpv 内部立刻恢复 pause=yes，
--      观察者回调要么不触发，要么触发时 pause 已被覆盖回 true
--    - 唯一可靠方案：直接修改 osc.lua 的 playpause 事件处理函数
--
-- 6. 拖放新文件时 pause 残留：
--    keep-open=always 在 EOF 时设置 pause=yes。如果此时拖放新文件，
--    start-file 事件触发，但 pause=yes 仍然生效，导致新文件需要手动点播放。
--    → 在 start-file 回调中主动 set_property_bool("pause", false)
--
-- 7. autoload.lua 无冲突：
--    autoload 在 start-file 时填充播放列表，但不强制播放。
--    本脚本用 keep-open 阻止当前文件"结束"，start-file 不会为下一个
--    文件触发，所以 autoload 没机会再次运行，两者和平共处。
--
-- 8. 文件解码/格式错误时的处理：
--    keep-open=always 只在文件正常到达 EOF 时生效。
--    如果文件因格式不支持、解码失败等原因无法播放：
--      ① mpv 触发 end-file 事件（reason="error"）
--      ② mpv 自动前进到下一个播放列表条目
--      ③ start-file 事件为下一个文件触发
--    keep-open 无法拦截这种情况。
--    → 解决方案：双事件协作
--      - end-file(reason="error") 时设置标志 error_stop_pending
--      - start-file 时检查标志，若为 true 则执行 stop 阻止播放
--    → 不在 end-file 中直接 stop：mpv 可能已在加载下一个文件，
--      时序不确定；在 start-file 中 stop 更可靠（mpv 刚开始加载，
--      stop 能干净地取消）
--
-- 【mpv Lua API 速查】
--
-- 核心模块：
--   local msg     = require 'mp.msg'      -- 日志: msg.info/warn/error/verbose/trace
--   local options = require 'mp.options'  -- 读配置: options.read_options(tbl, name, cb)
--   local utils   = require 'mp.utils'    -- 工具: utils.split_path, utils.readdir 等
--
-- 常用 API：
--   mp.get_property(name)                  → 返回字符串，出错返回 nil
--   mp.get_property_bool(name [,def])      → 返回 Lua boolean，出错返回 def
--   mp.get_property_native(name)           → 返回 Lua 原生类型（bool/number/table）
--   mp.get_property_number(name, default)  → 返回数字，出错返回 default
--   mp.set_property(name, value)           → 设置属性（字符串值）
--   mp.set_property_bool(name, value)      → 设置布尔属性（Lua boolean）
--   mp.commandv(cmd, arg1, arg2, ...)      → 执行命令（推荐，无需转义）
--
-- 事件与观察：
--   mp.register_event(name, fn)            → 注册事件回调
--     常用事件: start-file, file-loaded, end-file
--   mp.observe_property(name, type, fn)    → 观察属性变化
--     注意: 对于 pause 属性，mpv 可能在单次 playloop 中 yes→no→yes，
--     观察者可能只看到最终值，无法可靠检测中间的短暂变化
--
-- UI 交互：
--   mp.osd_message(text, duration)         → 屏幕显示文字，duration 单位秒
--   mp.add_forced_key_binding(key, name, fn) → 强制绑定（覆盖 input.conf）
--     注意: 只拦截键盘输入，无法拦截 OSC GUI 按钮点击
--
-- 【文件修改清单】
--
-- 本功能涉及两个文件：
-- 1. stop-after-current.lua（本文件）：keep-open 主机制 + Space 键拦截
-- 2. osc.lua playpause 按钮：加入 eof-reached 检查
--    查找 ne.eventresponder["mbtn_left_up"] 附近的 cycle pause，
--    替换为：
--      function ()
--          if mp.get_property_bool("eof-reached") then
--              mp.commandv("seek", "0", "absolute")
--              mp.set_property_bool("pause", false)
--          else
--              mp.commandv("cycle", "pause")
--          end
--      end
--
-- 【参考链接】
--   Lua 脚本 API: https://github.com/mpv-player/mpv/blob/master/DOCS/man/lua.rst
--   命令列表:     https://github.com/mpv-player/mpv/blob/master/DOCS/man/input.rst
--   属性列表:     https://mpv.io/manual/master/#properties
--   社区脚本:     https://github.com/mpv-player/mpv/wiki/User-Scripts
--
----------------------------------------------------------------------

local msg = require 'mp.msg'

local enabled = true
-- 保存原始值，关闭时恢复；or "no" 防止 get_property 返回 nil
local original_keep_open = mp.get_property("keep-open") or "no"

local function enable()
    if enabled then return end
    enabled = true
    mp.set_property("keep-open", "always")
    mp.osd_message("播放完自动停止: 开", 2)
    msg.info("enabled")
end

local function disable()
    if not enabled then return end
    enabled = false
    mp.set_property("keep-open", original_keep_open)
    mp.osd_message("播放完自动停止: 关", 2)
    msg.info("disabled")
end

local function toggle()
    if enabled then disable() else enable() end
end

-- 启用主机制
mp.set_property("keep-open", "always")

-- 绑定大写 P 键切换
mp.add_key_binding("P", "toggle-stop-after-current", toggle)

----------------------------------------------------------------------
-- 文件解码/格式错误：阻止跳到下一个文件
----------------------------------------------------------------------

local error_stop_pending = false

mp.register_event("end-file", function(event)
    if enabled and event.reason == "error" then
        error_stop_pending = true
        msg.info("File error (reason: error), will stop instead of advancing")
    end
end)

----------------------------------------------------------------------
-- 智能 播放/暂停：EOF 时重头播放
----------------------------------------------------------------------

-- 拖放新文件时确保开始播放 / 错误文件后停止
mp.register_event("start-file", function()
    if error_stop_pending then
        error_stop_pending = false
        msg.info("Stopping after file error")
        mp.command("stop")
        return
    end
    mp.set_property_bool("pause", false)
    msg.info("New file started, ensure playing")
end)

-- Space 键：EOF 时 seek 回开头重播
local function smart_play_pause()
    if mp.get_property_bool("eof-reached") then
        msg.info("EOF detected, restarting")
        mp.commandv("seek", "0", "absolute")
        mp.set_property_bool("pause", false)
    else
        mp.commandv("cycle", "pause")
    end
end

mp.add_forced_key_binding("Space", "smart-play-pause", smart_play_pause)
