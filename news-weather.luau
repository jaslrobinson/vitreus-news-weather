-- The News & Weather add-on's logic. News: settings (news.json), `vitreus-feedfetch` every so often, what was read (news-state.json) and the feed manager. Weather: an
-- Open-Meteo forecast fetched with `curl` (current conditions, 48 hours, 16 days), saved places by their coordinates (weather.json). Both are kept in this scene's own
-- data folder (~/.local/share/pleamar/news-weather), which the files service reads and writes by name.
-- Based on jaslrobinson's news drawer (Vitreus issue #22): news.luau and weather_plus.luau there, moved off the shell's own code and onto the add-on system. Differences:
-- feeds and places are typed in fields the shell takes the keys for (Ctrl+V pastes there), and the manager narrows the popular feeds as a feed is typed.
--
-- news.json: feeds { "name": "XDA", "url": "https://…/feed/" } (RSS or Atom; a feed may carry its own "block"), block (words that keep an item out: its title, address or
-- category, any case), minutes (15), max_items (40), per_feed (12), thumbnails (true), font (0.85 to 1.25). It is read again before each fetch.

local DATA = nil        -- this scene's data folder (the fetcher needs the path itself; the files service works by name)
local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function host_of(url) return (url or ""):match("^https?://([^/]+)") or "" end
local function urlenc(s) return (s:gsub("[^%w%-_%.~]", function(ch) return string.format("%%%02X", ch:byte()) end)) end
local function clone(t)
    local r = {}
    for k, v in pairs(t) do r[k] = type(v) == "table" and clone(v) or v end
    return r
end
local function r0(x) return math.floor((tonumber(x) or 0) + 0.5) end
local function clamp01(x) return math.max(0, math.min(1, x)) end

-- ════════════════════════════════ News ════════════════════════════════
local CFG_DEFAULT = {
    minutes = 15, max_items = 40, per_feed = 12, thumbnails = true, font = 1, block = {},
    feeds = {
        { name = "XDA", url = "https://www.xda-developers.com/feed/" },
        { name = "BBC News", url = "https://feeds.bbci.co.uk/news/rss.xml" },
    },
}
local cfg = {}
local function words(t)
    if type(t) ~= "table" then return nil end
    local r = {}
    for _, w in ipairs(t) do if type(w) == "string" and w ~= "" then r[#r + 1] = w end end
    return #r > 0 and r or nil
end
local function load_cfg()
    cfg = clone(CFG_DEFAULT)
    local ok, saved = pcall(sys.ask, "files.read", "news.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if k ~= "feeds" and type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
        if type(saved.feeds) == "table" then
            local feeds = {}
            for _, f in ipairs(saved.feeds) do
                if type(f) == "table" and type(f.url) == "string" and f.url:match("^https?://") then
                    feeds[#feeds + 1] = { name = type(f.name) == "string" and f.name or "", url = f.url, block = words(f.block) }
                end
            end
            cfg.feeds = feeds
        end
        cfg.block = words(cfg.block) or {}
        cfg.minutes = math.max(2, math.min(720, math.floor(cfg.minutes + 0.5)))
        cfg.max_items = math.max(5, math.min(40, math.floor(cfg.max_items + 0.5)))
        cfg.per_feed = math.max(1, math.min(50, math.floor(cfg.per_feed + 0.5)))
        cfg.font = math.max(0.85, math.min(1.25, cfg.font))
        return true
    end
    return false
end
local function save_cfg() pcall(sys.call, "files.write", "news.json", cfg) end

local read_ids = {}
local function load_state()
    read_ids = {}
    local ok, saved = pcall(sys.ask, "files.read", "news-state.json", "json")
    if ok and type(saved) == "table" and type(saved.read) == "table" then
        for _, id in ipairs(saved.read) do if type(id) == "string" then read_ids[id] = true end end
    end
end
local function save_state()
    local list = {}
    for id in pairs(read_ids) do list[#list + 1] = id end
    table.sort(list)
    while #list > 300 do table.remove(list, 1) end
    pcall(sys.call, "files.write", "news-state.json", { read = list })
end

local items = {}        -- every item of the last fetch: { id, t, src, link, pub, img, cat }
local feed_names = {}   -- the chips, after "All"
local last_ok, last_err, had_news = nil, nil, false

local function ago(pub)
    local d = os.time() - (pub or 0)
    if not pub or pub <= 0 or d < 0 then return "" end
    if d < 90 then return "now" end
    if d < 3600 then return string.format("%dm", math.floor(d / 60)) end
    if d < 86400 then return string.format("%dh", math.floor(d / 3600)) end
    if d < 7 * 86400 then return string.format("%dd", math.floor(d / 86400)) end
    local ok, s = pcall(os.date, "%b %d", pub)
    return ok and s or ""
end

local function shown_items()
    local want = tonumber(fact.news_filter) or 0
    local r = {}
    for _, it in ipairs(items) do
        local fi = 0
        for k, n in ipairs(feed_names) do if n == it.src then fi = k break end end
        if want == 0 or fi == want then r[#r + 1] = it end
        if #r >= cfg.max_items then break end
    end
    return r
end

local function publish()
    local rows, unread = {}, 0
    for _, it in ipairs(items) do if not read_ids[it.id] then unread = unread + 1 end end
    for _, it in ipairs(shown_items()) do
        local read = read_ids[it.id] and 1 or 0
        local cat = (it.cat or "")
        local meta = it.src .. (ago(it.pub) ~= "" and (" · " .. ago(it.pub)) or "") .. (cat ~= "" and #cat <= 24 and cat:lower() ~= it.src:lower() and (" · " .. cat) or "")
        rows[#rows + 1] = {
            t = it.t, meta = meta, read = read,
            img = (it.img or "") ~= "" and (it.img .. "?" .. (last_ok or 0)) or "",
            hasimg = (it.img or "") ~= "" and 1 or 0,
            ini = (it.src:sub(1, 1) or "?"):upper(),
        }
    end
    model.news_items = rows
    fact.news_unread = unread
    local chips = { { name = "All" } }
    for _, n in ipairs(feed_names) do chips[#chips + 1] = { name = n } end
    model.news_chips = chips
    local upd = last_ok and ("updated " .. (ago(last_ok) ~= "" and ago(last_ok) or "now")) or "not updated yet"
    text.news_sub = (unread > 0 and (unread .. " unread · ") or "") .. upd
    if #rows == 0 and #items > 0 then
        text.news_hint = "Nothing from this source yet — it lands on a later fetch."
    elseif #items == 0 then
        text.news_hint = last_err and (last_err .. "\nThe feeds are in news.json, in ~/.local/share/pleamar/news-weather.")
            or "Add a feed with the gear: copy an address, or r/subreddit, and press the button."
    else
        text.news_hint = ""
    end
end

local fetching = false
local arm_timer, publish_myfeeds, publish_dir
local function fetch_now()
    if fetching or not DATA then return end
    fetching = true
    fact.news_loading = true
    load_cfg()
    run("vitreus-feedfetch", { DATA .. "/news.json", DATA .. "/news" }, function(out, code)
        fetching = false
        fact.news_loading = false
        if code ~= 0 or not out then last_err = "The fetcher did not run (vitreus-feedfetch has to be in ~/.local/bin: run Vitreus's install.sh)." publish() after(60000, fetch_now) return end
        local ok, d = pcall(json.decode, out)
        if not ok or type(d) ~= "table" then last_err = "The fetcher's answer could not be read." publish() after(60000, fetch_now) return end
        feed_names = {}
        local errs = {}
        for _, f in ipairs(d.feeds or {}) do
            feed_names[#feed_names + 1] = f.name or "?"
            if not f.ok then errs[#errs + 1] = tostring(f.name) end
        end
        if type(d.items) == "table" and #d.items > 0 then
            items = d.items
            had_news = true
            last_ok = os.time()
            last_err = #errs > 0 and ("Could not update: " .. table.concat(errs, ", ")) or nil
        elseif not had_news then
            last_err = "All RSS feeds failed to update"
        end
        if (tonumber(fact.news_filter) or 0) > #feed_names then fact.news_filter = 0 end
        if had_news then pcall(sys.call, "files.write", "news-cache.json", { names = feed_names, items = items, at = last_ok }) end      -- shown at once next time
        arm_timer()
        publish()
        publish_myfeeds()
        publish_dir()
    end)
end

every(60000, function() publish() end)     -- the ages ("4m") grow stale on their own
local fetch_timer, armed_minutes = nil, 0
arm_timer = function()
    if fetch_timer and armed_minutes == cfg.minutes then return end
    if fetch_timer then cancel(fetch_timer) fetch_timer = nil end
    armed_minutes = cfg.minutes
    fetch_timer = every(cfg.minutes * 60000, function() fetch_now() end)
end

local function nth_shown(i) return shown_items()[math.floor((tonumber(i) or -1) + 0.5) + 1] end
on("news_refresh", function() fetch_now() end)
on("news_chip", function(i)
    fact.news_filter = math.max(0, math.min(#feed_names, math.floor((tonumber(i) or 0) + 0.5)))
    publish()
end)
on("news_open", function(i)
    local it = nth_shown(i)
    if not it then return end
    read_ids[it.id] = true
    save_state()
    publish()
    if it.link and it.link ~= "" then run("xdg-open", { it.link }, function() end, { output = false }) end
end)
on("news_read", function(i)
    local it = nth_shown(i)
    if not it then return end
    read_ids[it.id] = true
    save_state()
    publish()
end)
on("news_read_all", function()
    for _, it in ipairs(items) do read_ids[it.id] = true end
    save_state()
    publish()
end)

-- ── the feed manager (the tab's gear) ──
local directory = {}
local function load_directory()
    run("vitreus-feedfetch", { "--directory" }, function(out, code)
        if code ~= 0 or not out then return end
        local ok, d = pcall(json.decode, out)
        if ok and type(d) == "table" and type(d.list) == "table" then directory = d.list publish_dir() end
    end)
end
local function have_feed(url)
    for _, f in ipairs(cfg.feeds) do if f.url == url then return true end end
    return false
end
-- ════════════════════════════════ the field ════════════════════════════════
-- One field at a time, the feed manager's or the place search's, typed through the shell: this says where it is (from the top left of the content, in the scene's
-- `u` of 1.1; `axf_r` from the right edge) and the shell sends back `field_q`, `field_kb`, `field_enter` and `field_esc` (Ctrl+V pastes, in the shell).
local U = 1.1
local field = nil              -- "feed", "place" or nil: which one is shown
local last_q = nil             -- the writing last acted on
local function say_shell(cmds)
    local args = { "--say", "vitreus" }
    for _, c in ipairs(cmds) do args[#args + 1] = c end
    run("pleamar", args, function() end)
end
local function place_field()
    local l, t, r = 22, 110, 50                    -- (the right end leaves room for the "…" shown while a feed is looked up)
    if field == "place" then l, t, r = 30, 97, 30 end
    say_shell({ "fact axf_l " .. l * U, "fact axf_t " .. t * U, "fact axf_r " .. r * U, "fact axf_h " .. 34 * U, "text axf_q " .. (text.field_q or ""), "fact axf_on true", "emit axf_set" })       -- (`axf_set`: already on, from the other field, it would keep that one's writing)
end
local function set_field_text(v)       -- the add-on's own change of what is written (emptied after adding, the clipboard's)
    text.field_q = v
    last_q = v
    say_shell({ "text axf_q " .. v, "emit axf_set" })
end
local publish_dir_now
local function update_field()          -- which field the panel shows now; after any change of the tab, the manager or the place search
    local want = nil
    if fact.news_tab == 0 and fact.news_mng == true then want = "feed"
    elseif fact.news_tab == 1 and fact.wxp_adding == true then want = "place" end
    if want == field then return end
    field = want
    text.field_q = ""
    last_q = ""
    if field then place_field() else say_shell({ "fact axf_on false" }) end
    if publish_dir_now then publish_dir_now() end
end
-- The shell forgets the field when the panel shuts: told again as it comes out (with what was written, which it then keeps).
local was_open = false
on("fact:slot_open", function(v)       -- (said again every two seconds while the panel is out: only its coming out counts, or the field would be set back to a moment ago)
    local now = v == true
    if now == was_open then return end
    was_open = now
    if now and field then place_field() end
end)
on("fact:news_tab", function() update_field() end)

local sugg_items = {}
publish_dir = function()       -- the popular feeds that are not in yet; with something written in the field, the ones that match it (and the writing itself, to look up)
    sugg_items = {}
    local rows = {}
    local q = field == "feed" and trim(text.field_q) or ""
    local ql = q:lower()
    fact.news_qon = q ~= ""
    if q ~= "" and (q:find("://", 1, true) or (q:find(".", 1, true) and not q:find(" ", 1, true)) or q:match("^r/")) then
        sugg_items[1] = { name = "Add “" .. q .. "”", resolve = q }
        rows[1] = { name = sugg_items[1].name, sub = "find its feed" }
    end
    for _, d in ipairs(directory) do
        local hit = ql == "" or d.name:lower():find(ql, 1, true) or (d.topic or ""):lower():find(ql, 1, true) or d.url:lower():find(ql, 1, true)
        if hit and not have_feed(d.url) and #sugg_items < 30 then
            sugg_items[#sugg_items + 1] = d
            rows[#rows + 1] = { name = d.name, sub = (d.topic or "") .. " · " .. host_of(d.url) }
        end
    end
    model.news_sugg = rows
end
publish_dir_now = function() publish_dir() end
publish_myfeeds = function()
    local rows = {}
    for i, f in ipairs(cfg.feeds) do
        if i > 10 then break end
        rows[i] = { name = f.name ~= "" and f.name or host_of(f.url), sub = host_of(f.url) }
    end
    model.news_feeds = rows
end
local function say(msg) text.news_mng_msg = msg end
local function apply_feed(name, url)
    if have_feed(url) then say("already in your feeds") return end
    cfg.feeds[#cfg.feeds + 1] = { name = name, url = url }
    save_cfg()
    publish_myfeeds()
    if field == "feed" then set_field_text("") end
    publish_dir()
    say("added " .. name)
    fetch_now()
end
local resolving = false
local function resolve_and_add(q)
    if resolving then return end
    resolving = true
    fact.news_mng_busy = true
    say("checking…")
    run("vitreus-feedfetch", { "--resolve", q }, function(out, code)
        resolving = false
        fact.news_mng_busy = false
        local ok, d = pcall(json.decode, out or "")
        if code == 0 and ok and type(d) == "table" and d.ok and d.url then
            apply_feed(d.name ~= "" and d.name or q, d.url)
        else
            say("no feed found there")
        end
    end)
end
local function pick_feed(d)
    if not d then return end
    if d.resolve then resolve_and_add(d.resolve) else apply_feed(d.name, d.url) end
end
on("news_mng_pick", function(i) pick_feed(sugg_items[math.floor((tonumber(i) or -1) + 0.5) + 1]) end)
on("news_mng_del", function(i)
    local k = math.floor((tonumber(i) or -1) + 0.5) + 1
    local f = cfg.feeds[k]
    if not f then return end
    table.remove(cfg.feeds, k)
    save_cfg()
    local kept = {}
    for _, it in ipairs(items) do if it.src ~= f.name then kept[#kept + 1] = it end end
    items = kept
    publish_myfeeds()
    publish_dir()
    publish()
    say("removed " .. (f.name ~= "" and f.name or host_of(f.url)))
    fetch_now()
end)
on("fact:news_mng", function(v)
    if v then say("") publish_myfeeds() end
    update_field()
    publish_dir()
end)
on("news_font", function(d)
    cfg.font = math.max(0.85, math.min(1.25, math.floor((cfg.font + (tonumber(d) or 0) * 0.05) * 100 + 0.5) / 100))
    fact.news_fsz = cfg.font
    save_cfg()
end)

-- The tab in use, kept once it has stopped changing for a moment (news-sheet.json).
local tab_token = 0
on("fact:news_tab", function()
    tab_token = tab_token + 1
    local t = tab_token
    after(500, function()
        if t ~= tab_token then return end
        pcall(sys.call, "files.write", "news-sheet.json", { tab = tonumber(fact.news_tab) or 0 })
    end)
end)
do
    local ok, s = pcall(sys.ask, "files.read", "news-sheet.json", "json")
    if ok and type(s) == "table" and type(s.tab) == "number" then fact.news_tab = s.tab end
end

-- ════════════════════════════════ Weather ════════════════════════════════
local WX_DESC = {
    [0] = "Clear sky", [1] = "Mainly clear", [2] = "Partly cloudy", [3] = "Overcast",
    [45] = "Foggy", [48] = "Rime fog", [51] = "Light drizzle", [53] = "Drizzle", [55] = "Dense drizzle",
    [56] = "Freezing drizzle", [57] = "Freezing drizzle", [61] = "Slight rain", [63] = "Rain", [65] = "Heavy rain",
    [66] = "Freezing rain", [67] = "Freezing rain", [71] = "Light snow", [73] = "Snow", [75] = "Heavy snow",
    [77] = "Snow grains", [80] = "Light showers", [81] = "Showers", [82] = "Violent showers",
    [85] = "Snow showers", [86] = "Heavy snow showers", [95] = "Thunderstorm", [96] = "Thunderstorm, hail",
    [99] = "Severe thunderstorm",
}
local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local function kind(code)              -- 0 clear · 1 partly · 2 cloud · 3 fog · 4 rain · 5 snow · 6 storm
    code = tonumber(code) or 3
    if code == 0 then return 0 end
    if code == 1 or code == 2 then return 1 end
    if code == 3 then return 2 end
    if code == 45 or code == 48 then return 3 end
    if (code >= 51 and code <= 67) or (code >= 80 and code <= 82) then return 4 end
    if (code >= 71 and code <= 77) or code == 85 or code == 86 then return 5 end
    if code >= 95 then return 6 end
    return 2
end
local function parse(iso)              -- "2026-10-23T18:00" (already the place's own time) → a date table with its weekday
    local y, m, d, hh, mm = (iso or ""):match("^(%d+)-(%d+)-(%d+)T?(%d*):?(%d*)")
    if not y then return nil end
    -- os.time reads the table as UTC here and os.date("*t") would turn it to local time, moving every hour by the offset: "!*t" keeps it as written
    return os.date("!*t", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(hh) or 12, min = tonumber(mm) or 0 }))
end
local function clock(t, mins)
    if not t then return "—" end
    local h = t.hour % 12
    if h == 0 then h = 12 end
    return mins and string.format("%d:%02d %s", h, t.min, t.hour < 12 and "AM" or "PM") or (h .. (t.hour < 12 and " AM" or " PM"))
end

local wcfg = { units = "fahrenheit", places = {}, sel = nil }       -- sel: the place chosen (by its coordinates), or nil: follow me
local function place(p)
    if type(p) == "table" and type(p.name) == "string" and type(p.lat) == "number" and type(p.lon) == "number" then return { name = p.name, lat = p.lat, lon = p.lon } end
end
local function save_wcfg() pcall(sys.call, "files.write", "weather.json", wcfg) end
local function load_wcfg()
    local ok, saved = pcall(sys.ask, "files.read", "weather.json", "json")
    if ok and type(saved) == "table" then
        if saved.units == "celsius" or saved.units == "fahrenheit" then wcfg.units = saved.units end
        if type(saved.places) == "table" then
            for _, p in ipairs(saved.places) do if place(p) then wcfg.places[#wcfg.places + 1] = place(p) end end
        end
        wcfg.sel = place(saved.sel)
        return true
    end
    return false
end

local function show_weather(w)
    if type(w) ~= "table" or type(w.current) ~= "table" or type(w.hourly) ~= "table" or type(w.daily) ~= "table" then return false end
    local cu = type(w.current_units) == "table" and w.current_units or {}
    local c = cu.temperature_2m == "°C" or (cu.temperature_2m == nil and wcfg.units == "celsius")   -- the answer's own units, not the setting's
    local cur = w.current
    local code = cur.weather_code or 3
    text.nw_temp = r0(cur.temperature_2m) .. (c and "°C" or "°F")
    text.nw_desc = WX_DESC[code] or "—"
    fact.nw_kind = kind(code)
    local function nz(v, f) if type(v) == "number" then return f(v) end return "—" end
    text.nw_feels = nz(cur.apparent_temperature, function(v) return r0(v) .. "°" end)
    text.nw_hum = nz(cur.relative_humidity_2m, function(v) return r0(v) .. "%" end)
    local dirs = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
    text.nw_wind = nz(cur.wind_speed_10m, function(v)
        local d = type(cur.wind_direction_10m) == "number" and (" " .. dirs[math.floor((cur.wind_direction_10m + 22.5) / 45) % 8 + 1]) or ""
        return r0(v) .. (c and " km/h" or " mph") .. d
    end)
    local d = w.daily
    local pp = d.precipitation_probability_max
    text.nw_rain = nz(type(pp) == "table" and pp[1] or nil, function(v) return r0(v) .. "%" end)
    fact.nw_c = c

    local amt_unit = c and " mm" or " in"
    local wind_unit = c and " km/h" or " mph"
    local h = w.hourly
    local n = math.min(48, #(h.time or {}))
    local T, F, P, A, W, G, U = h.temperature_2m or {}, h.apparent_temperature or {}, h.precipitation_probability or {}, h.precipitation or {}, h.wind_speed_10m or {}, h.wind_gusts_10m or {}, h.uv_index or {}
    local lo, hi, amax, wmax = math.huge, -math.huge, c and 5 or 0.2, 10
    for i = 1, n do
        for _, v in ipairs({ T[i], F[i] }) do if type(v) == "number" then lo, hi = math.min(lo, v), math.max(hi, v) end end
        if type(A[i]) == "number" then amax = math.max(amax, A[i]) end
        if type(G[i]) == "number" then wmax = math.max(wmax, G[i]) end
        if type(W[i]) == "number" then wmax = math.max(wmax, W[i]) end
    end
    if lo > hi then lo, hi = 0, 1 end
    lo, hi = math.floor(lo - 2), math.ceil(hi + 2)
    local function tn(v) return type(v) == "number" and clamp01((v - lo) / (hi - lo)) or 0 end
    local rows = {}
    for i = 1, n do
        local t = parse(h.time[i])
        local lbl = ""
        if i == 1 then lbl = "now"
        elseif t and t.hour == 0 then lbl = DAYS[t.wday]
        elseif t and t.hour % 6 == 0 then lbl = clock(t) end
        local amount = type(A[i]) == "number" and A[i] or 0
        rows[i] = {
            t = tn(T[i]), t2 = tn(T[math.min(i + 1, n)]), f = tn(F[i]), f2 = tn(F[math.min(i + 1, n)]),
            p = clamp01((tonumber(P[i]) or 0) / 100), a = clamp01(amount / amax),
            w = clamp01((tonumber(W[i]) or 0) / wmax), w2 = clamp01((tonumber(W[math.min(i + 1, n)]) or 0) / wmax),
            g = clamp01((tonumber(G[i]) or 0) / wmax), uv = clamp01((tonumber(U[i]) or 0) / 11),
            day = (t and t.hour == 0 and i > 1) and 1 or 0, lbl = lbl,
            tip = (t and clock(t) or "") .. " · " .. r0(T[i]) .. "° (feels " .. r0(F[i]) .. "°) · " .. r0(P[i]) .. "%"
                .. (amount > 0 and (" · " .. (c and string.format("%.1f", amount) or string.format("%.2f", amount)) .. amt_unit) or "")
                .. " · wind " .. r0(W[i]) .. wind_unit .. " · UV " .. r0(U[i]),
        }
    end
    model.wxh = rows
    text.wxp_tmax = hi .. "°"
    text.wxp_tmin = lo .. "°"

    local dn = math.min(16, #(d.time or {}))
    local dlo, dhi = math.huge, -math.huge
    for i = 1, dn do
        if type(d.temperature_2m_min[i]) == "number" then dlo = math.min(dlo, d.temperature_2m_min[i]) end
        if type(d.temperature_2m_max[i]) == "number" then dhi = math.max(dhi, d.temperature_2m_max[i]) end
    end
    if dlo > dhi then dlo, dhi = 0, 1 end
    local days = {}
    for i = 1, dn do
        local t = parse(d.time[i])
        local p2 = d.precipitation_probability_max and d.precipitation_probability_max[i]
        days[i] = {
            lbl = i == 1 and "Today" or (t and DAYS[t.wday] .. " " .. t.day or "—"),
            k = kind(d.weather_code[i]),
            pop = type(p2) == "number" and (r0(p2) .. "%") or "",
            popn = type(p2) == "number" and clamp01(p2 / 100) or 0,
            lo = clamp01(((d.temperature_2m_min[i] or dlo) - dlo) / (dhi - dlo)),
            hi = clamp01(((d.temperature_2m_max[i] or dhi) - dlo) / (dhi - dlo)),
            lot = r0(d.temperature_2m_min[i]) .. "°", hit = r0(d.temperature_2m_max[i]) .. "°",
        }
    end
    model.wxd = days
    if dn > 0 then
        text.wxp_hilo = "H " .. r0(d.temperature_2m_max[1]) .. "°  ·  L " .. r0(d.temperature_2m_min[1]) .. "°"
        local sr, ss = d.sunrise and parse(d.sunrise[1]), d.sunset and parse(d.sunset[1])
        text.wxp_sun = "Sunrise " .. clock(sr, true) .. "  ·  Sunset " .. clock(ss, true)
    end
    fact.wxp_ok = n > 1
    return true
end

local function same(a, b) return a and b and math.abs(a.lat - b.lat) < 0.01 and math.abs(a.lon - b.lon) < 0.01 end
local function publish_places()
    local rows, sel = {}, -1
    for i, p in ipairs(wcfg.places) do
        if i > 8 then break end
        rows[i] = { name = p.name:match("^[^,]+") or p.name }
        if same(p, wcfg.sel) then sel = i - 1 end
    end
    model.wxp_places = rows
    fact.wxp_sel = sel
end

local wx_busy, wx_again, wx_at = false, false, 0
local follow_loc = nil          -- where "follow me" is, looked up once a session (and again when it is picked)
local function wx_forecast(loc)
    local unit = wcfg.units == "celsius" and "celsius" or "fahrenheit"
    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. loc.lat .. "&longitude=" .. loc.lon
        .. "&current=temperature_2m,weather_code,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
        .. "&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,wind_speed_10m,wind_gusts_10m,uv_index"
        .. "&wind_speed_unit=" .. (unit == "celsius" and "kmh" or "mph") .. "&temperature_unit=" .. unit .. "&timezone=auto&forecast_days=16&forecast_hours=48"
    run("curl", { "-s", "-L", "--max-time", "12", url }, function(out, code)
        local ok, w = pcall(json.decode, out or "")
        local shown = code == 0 and ok and show_weather(w)
        if shown then
            wx_at = os.time()
            fact.wxp_failed = false
            pcall(sys.call, "files.write", "wx-cache.json", w)
        elseif not fact.wxp_ok then
            fact.wxp_failed = true
            text.wxp_load = "Could not get the forecast — trying again in a minute"
        end
        wx_busy = false
        if wx_again then wx_again = false; after(100, function() refresh_weather() end) return end
        if not shown then after(60000, function() if not wx_busy then refresh_weather() end end) end
    end)
end
function refresh_weather()
    if wx_busy then wx_again = true return end
    wx_busy = true
    if wcfg.sel then wx_forecast(wcfg.sel) return end
    if follow_loc then wx_forecast(follow_loc) return end
    -- Follow me: the place the shell is set to (weather-config.json, next to this folder) or, with none set, where the IP says
    run("cat", { DATA:gsub("/[^/]+$", "") .. "/vitreus/weather-config.json" }, function(out, code)
        local ok, sc = pcall(json.decode, out or "")
        local loc = (code == 0 and ok and type(sc) == "table" and type(sc.location) == "string") and trim(sc.location) or ""
        local url = loc ~= "" and ("https://geocoding-api.open-meteo.com/v1/search?name=" .. urlenc(loc) .. "&count=1&format=json") or "https://ipwho.is/"
        run("curl", { "-s", "-L", "--max-time", "10", url }, function(o2, c2)
            local ok2, r = pcall(json.decode, o2 or "")
            local lat, lon
            if c2 == 0 and ok2 and type(r) == "table" then
                if loc ~= "" and type(r.results) == "table" and r.results[1] then lat, lon = r.results[1].latitude, r.results[1].longitude
                elseif loc == "" and r.success then lat, lon = r.latitude, r.longitude end
            end
            if type(lat) == "number" and type(lon) == "number" then
                follow_loc = { lat = lat, lon = lon }
                wx_forecast(follow_loc)
            else
                wx_busy = false
                after(60000, function() if not wx_busy then refresh_weather() end end)
            end
        end)
    end)
end

on("wxp_pick", function(i)
    local k = math.floor((tonumber(i) or -1) + 0.5)
    if k < 0 then
        wcfg.sel = nil
        follow_loc = nil
    else
        wcfg.sel = wcfg.places[k + 1] and place(wcfg.places[k + 1]) or wcfg.sel
    end
    save_wcfg()
    publish_places()
    refresh_weather()
end)
on("wxp_del", function(i)
    local k = math.floor((tonumber(i) or -1) + 0.5) + 1
    local p = wcfg.places[k]
    if not p then return end
    table.remove(wcfg.places, k)
    if same(p, wcfg.sel) then wcfg.sel = nil end
    save_wcfg()
    publish_places()
    refresh_weather()
end)
on("nw_units_set", function(i)
    wcfg.units = (tonumber(i) or 0) >= 0.5 and "celsius" or "fahrenheit"
    save_wcfg()
    fact.nw_c = wcfg.units == "celsius"
    refresh_weather()
end)

-- adding a place: the field looks it up as it is written; Open-Meteo's geocoding gives several per name (with region and
-- country), and one is picked (Enter: the first)
local found = {}
local look_token = 0
local function clear_adding()       -- what the search held (not the fact itself: its own handler calls this)
    look_token = look_token + 1
    found = {}
    model.wxp_sugg = {}
    text.wxp_msg = ""
end
local function close_adding()
    fact.wxp_adding = false       -- (set here, it does not fire its own handler)
    clear_adding()
    update_field()
end
local function look(q)
    look_token = look_token + 1
    local tok = look_token
    found = {}
    if #q < 2 then model.wxp_sugg = {} text.wxp_msg = "" return end
    after(350, function()       -- once the writing has paused
        if tok ~= look_token then return end
        text.wxp_msg = "looking it up…"
        run("curl", { "-s", "-L", "--max-time", "8", "https://geocoding-api.open-meteo.com/v1/search?name=" .. urlenc(q) .. "&count=6&format=json" }, function(o2, c2)
            if tok ~= look_token then return end
            found = {}
            local ok, res = pcall(json.decode, o2 or "")
            local rows = {}
            if c2 == 0 and ok and type(res) == "table" then
                for _, g in ipairs(res.results or {}) do
                    if type(g.latitude) == "number" and type(g.longitude) == "number" then
                        local sub = (g.admin1 or "") .. (g.country_code and ((g.admin1 and ", " or "") .. g.country_code) or "")
                        found[#found + 1] = { name = tostring(g.name) .. (g.admin1 and (", " .. g.admin1) or ""), lat = g.latitude, lon = g.longitude }
                        rows[#rows + 1] = { name = tostring(g.name), sub = sub }
                    end
                    if #found >= 6 then break end
                end
            end
            model.wxp_sugg = rows
            text.wxp_msg = #rows == 0 and "no place by that name" or ""
        end)
    end)
end
on("fact:wxp_adding", function(v)
    if v ~= true then clear_adding() end
    update_field()
end)
local function add_place(p)
    if not p then return end
    local have = false
    for _, q in ipairs(wcfg.places) do if same(q, p) then have = true end end
    if not have and #wcfg.places < 8 then wcfg.places[#wcfg.places + 1] = { name = p.name, lat = p.lat, lon = p.lon } end
    wcfg.sel = place(p)
    save_wcfg()
    close_adding()
    publish_places()
    refresh_weather()
end
on("wxp_add", function(i) add_place(found[math.floor((tonumber(i) or -1) + 0.5) + 1]) end)

-- what the shell sends from the field
on("text:field_q", function()
    local q = text.field_q or ""
    if q == last_q then return end       -- (sent again with Enter: looking up the same words afresh dropped the places found, which Enter takes the first of)
    last_q = q
    if field == "feed" then publish_dir() elseif field == "place" then look(trim(q)) end
end)
on("field_enter", function()
    if field == "feed" then
        local q = trim(text.field_q)
        if q == "" then return end
        if sugg_items[1] then pick_feed(sugg_items[1]) else resolve_and_add(q) end
    elseif field == "place" then
        add_place(found[1])
    end
end)
on("field_esc", function()
    if field == "feed" then
        fact.news_mng = false       -- (set here, it does not fire its own handler)
        update_field()
        publish_dir()
    elseif field == "place" then
        close_adding()
    end
end)

-- an open drawer with an old forecast asks for a new one
on("fact:slot_open", function(v)
    if v == true and DATA and os.time() - wx_at > 600 then refresh_weather() end
end)

-- ════════════════════════════════ start ════════════════════════════════
local function start()
    if not load_cfg() then save_cfg() end       -- the fetcher reads the file itself: it has to be there
    do   -- what the last fetch brought, while the next is on its way
        local ok, c = pcall(sys.ask, "files.read", "news-cache.json", "json")
        if ok and type(c) == "table" and type(c.items) == "table" and #c.items > 0 then
            items, feed_names, last_ok, had_news = c.items, type(c.names) == "table" and c.names or {}, tonumber(c.at), true
        end
    end
    do
        local ok, w = pcall(sys.ask, "files.read", "wx-cache.json", "json")
        if ok and type(w) == "table" then pcall(show_weather, w) end
    end
    load_state()
    fact.news_fsz = cfg.font
    publish()
    publish_myfeeds()
    load_directory()
    arm_timer()
    fetch_now()
    if not load_wcfg() then
        save_wcfg()
    end
    fact.nw_c = wcfg.units == "celsius"
    publish_places()
    refresh_weather()
    every(1800000, function() refresh_weather() end)       -- every half hour
end
-- It starts once the data folder's path is known. A scene started again (the switch turned off and on) may ask before the files service answers, so it asks again a few
-- times, and once more when the panel opens, rather than staying empty for good.
local started = false
local function try_start()
    if started then return end
    local ok, folder = pcall(sys.ask, "files.folder")
    if ok and type(folder) == "string" and folder ~= "" then
        started = true
        DATA = (folder:gsub("/+$", ""))
        start()
    end
end
try_start()
for _, ms in ipairs({ 500, 1500, 4000, 10000 }) do after(ms, try_start) end
on("fact:slot_open", function(v) if v == true then try_start() end end)
