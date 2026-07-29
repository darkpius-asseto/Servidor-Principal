--[[ ==========================================================================
     DRKZ - UI 2.0   |   ONLINE SCRIPT (server-pushed, no client install)
     --------------------------------------------------------------------------
     Delivered by the server via CSP extra options [SCRIPT_0]. Runs on every
     client automatically. Entry points at the bottom: script.update + drawUI.
     --------------------------------------------------------------------------
     Fixed rendering model (this is the important bit):
       * The fullscreen HUD is drawn from the manifest's [UI_CALLBACKS] IN_GAME
         callback -> drkzMain(dt). That callback does NOT run inside a window,
         so every panel makes its own window with the REAL SDK function:
              ui.transparentWindow(id, pos, size, noPadding, inputs, content)
         (content is a function; drawing inside it is window-local, 0,0 = the
         window's top-left.)
       * A tiny control window (windowMain) is the icon in the app bar. It has a
         master ON/OFF plus Reset. The HUD keeps drawing even when it's closed.

     Live systems (all work on ANY CSP server, no server script needed):
       * PROXIMITY SCORING  - points for driving fast CLOSE to other players.
       * MULTIPLIERS        - Combo / Speed / Proximity, live.
       * PERSONAL BEST      - session + all-time PB saved to disk.
       * NEARBY DRIVERS     - auto list by distance, scores shared peer-to-peer.
       * CHAT               - real server chat: receive + send.
       * SPEEDO / PAINT     - live telemetry / live body colour.

     Optional drkz_server.lua adds a saved, server-wide leaderboard.

     Everything risky is guarded; if drkzMain errors it is caught and the error
     is printed on screen AND to the CSP log, so it can never silently blank.
     ====================================================================== ]]--

------------------------------------------------------------------------------
-- 0. COMPAT SHIM
------------------------------------------------------------------------------

local FONT_R, FONT_B, FONT_X = 'Segoe UI', 'Segoe UI;Weight=Bold', 'Segoe UI;Weight=Black'
local hasDWrite = ui.dwriteDrawText ~= nil and ui.measureDWriteText ~= nil

local function setFont(w) if hasDWrite then ui.pushDWriteFont(w or FONT_R) end end
local function unsetFont() if hasDWrite then ui.popDWriteFont() end end

local function T(pos, s, size, col, weight)
  if hasDWrite then setFont(weight or FONT_R); ui.dwriteDrawText(s, size, pos, col); unsetFont()
  else ui.drawText(tostring(s), pos, col) end
end
local function TW(s, size, weight)
  if hasDWrite then setFont(weight or FONT_R); local m = ui.measureDWriteText(s, size); unsetFont(); return m.x end
  local ok, m = pcall(ui.measureText, s); return ok and m.x or (#tostring(s) * size * 0.5)
end
local function TC(pos, w, s, size, col, weight) T(vec2(pos.x + (w - TW(s, size, weight)) / 2, pos.y), s, size, col, weight) end
local function TR(pos, w, s, size, col, weight) T(vec2(pos.x + w - TW(s, size, weight), pos.y), s, size, col, weight) end

local canBlur = ui.beginBlurring ~= nil and ui.endBlurring ~= nil
local function mouseDown()    return ui.mouseDown    and ui.mouseDown(0)    or false end
local function mouseClicked() return ui.mouseClicked and ui.mouseClicked(0) or false end
local function mouseDelta()   return ui.mouseDelta   and ui.mouseDelta()    or vec2(0, 0) end
local function mouseWheel()   return ui.mouseWheel   and ui.mouseWheel()    or 0 end

-- screen resolution (the IN_GAME callback has no window to ask)
local function screenSize()
  local ok, s = pcall(function() return ac.getUI().windowSize end)
  if ok and s and s.x and s.x > 0 then return s end
  local sim = ac.getSim and ac.getSim() or nil
  if sim and sim.windowWidth and sim.windowWidth > 0 then return vec2(sim.windowWidth, sim.windowHeight) end
  return vec2(1920, 1080)
end

local function driverName(i)
  local ok, n = pcall(ac.getDriverName, i)
  if ok and n and n ~= '' then return n end
  return 'Car ' .. i
end

------------------------------------------------------------------------------
-- 1. PALETTE
------------------------------------------------------------------------------

local function hex(h, alpha)
  local n = tonumber(h, 16)
  return rgbm(math.floor(n / 65536) / 255, math.floor(n / 256) % 256 / 255, n % 256 / 255, alpha or 1)
end

local C = {
  plate = rgbm(0.047,0.051,0.063,0.88), plateSub = rgbm(1,1,1,0.035), quote = rgbm(1,1,1,0.05),
  edge = rgbm(1,1,1,0.07), edgeHi = rgbm(1,1,1,0.14), slot = rgbm(1,1,1,0.05), chip = rgbm(1,1,1,0.08),
  white = hex('FFFFFF'), soft = hex('C8C8D0'), muted = hex('8B8B93'), faint = hex('7A7A84'),
  ink = hex('15151C'), inkGreen = hex('0A2410'),
  greenA = hex('3FD35C'), greenB = hex('A9F03A'), greenIco = hex('3DFF70'), greenBg = hex('0D1A10'),
  hp = hex('22D94E'), grayBox = hex('4E545E'), barWhite = hex('F2F2F5'),
  purpA = hex('9B1FE8'), purpB = hex('C93CF0'), purpC = hex('E88CF5'),
  pink = hex('FF45A8'), purple = hex('B45CFF'), orange = hex('F0641E'), off = hex('3A3D46'),
  nPurple = hex('B45CFF'), whisper = hex('5AA8F0'), sys = hex('22D94E'),
}

------------------------------------------------------------------------------
-- 2. STORAGE
------------------------------------------------------------------------------

local S = ac.storage{
  pPB='22,33', sPB=1.0, pPts='1240,40', sPts=1.0, pCrew='-4,206', sCrew=1.0,
  pChat='1440,205', sChat=1.0, pSpd='1520,860', sSpd=1.0, pStat='8,1040', sStat=1.0,
  hudEnabled=true, showUI=true, showSpeedo=true, showChat=false, showCrew=false,
  bodyHex='#0B1D47', pbScore=0, rankPts=0,
}
local function unpack2(s) local x,y=s:match('(-?[%d%.]+),(-?[%d%.]+)'); return vec2(tonumber(x) or 0, tonumber(y) or 0) end
local function pack2(v) return string.format('%.0f,%.0f', v.x, v.y) end
local function comma(n)
  local s = string.format('%d', math.floor((n or 0) + 0.5)); local out, cnt = '', 0
  for i = #s, 1, -1 do out = s:sub(i,i)..out; cnt = cnt+1; if cnt%3==0 and i>1 then out=','..out end end
  return out
end

------------------------------------------------------------------------------
-- 3. LIVE STATE
------------------------------------------------------------------------------

local now = 0
local me = { session=0, pb=S.pbScore, combo=1, comboT=0, speedMul=1, proxMul=1, nearby=0, kmh=0, lives=2 }
local nearby, remote = {}, {}
local chatLines, chatDraft, chatWhisper = {}, '', false

-- No Hesi UI 2.0 style scoring: points come from CUTS (near-misses), a combo
-- multiplier that decays if you stop cutting, and a 2-lives crash system.
local prevKmh          = 0
local crashCooldownEnd = 0     -- can't register another crash until this time
local speedoFlashEnd   = 0     -- speedo flashes red until this time
local vignetteStart, vignetteEnd = -10, -10   -- full-screen red flash timing
local diagLogged = false

local PROX_RANGE, PROX_CLOSE = 32, 8
-- CONTINUOUS proximity scoring: points keep climbing while you cruise fast
-- through traffic. Combo builds over time and decays when you stop.
local MIN_CRUISE  = 80         -- km/h: below this you earn nothing
local BASE_RATE   = 9000       -- points-per-second scale at combo 1
local COMBO_MAX   = 12         -- seconds of sustained scoring for max combo
local COMBO_GAIN  = 0.5        -- combo added per second scored
local COMBO_DECAY = 2.5        -- combo timer lost per second when not scoring
-- crash tuning (2 lives)
local CRASH_DROP     = 40      -- km/h dropped in one frame = a crash
local CRASH_COOLDOWN = 2.0     -- seconds of immunity after a crash

-- abbreviate huge numbers: 1234 -> 1.23K, 1.2e6 -> 1.20M, 3.4e9 -> 3.40B
local function shortNum(n)
  n = n or 0
  local a = math.abs(n)
  if a >= 1e12 then return string.format('%.2fT', n/1e12) end
  if a >= 1e9  then return string.format('%.2fB', n/1e9)  end
  if a >= 1e6  then return string.format('%.2fM', n/1e6)  end
  if a >= 1e3  then return string.format('%.1fK', n/1e3)  end
  return string.format('%.0f', n)
end

------------------------------------------------------------------------------
-- 4. NETWORK + CHAT
------------------------------------------------------------------------------

local netOK, scoreEvt = false, nil
local function initNet()
  if not ac.OnlineEvent then return end
  pcall(function()
    scoreEvt = ac.OnlineEvent({
      ac.StructItem.key('DRKZ_UI2_score'),
      score = ac.StructItem.int32(), combo = ac.StructItem.float(),
    }, function(sender, data)
      if not sender or sender.index == nil or sender.index < 1 then return end
      local key = sender.sessionID or sender.index
      remote[key] = { name=driverName(sender.index), score=data.score or 0, combo=data.combo or 1, index=sender.index, t=now }
    end)
    netOK = scoreEvt ~= nil
  end)
end
local lastBroadcast = 0
local function broadcastScore()
  if not netOK or not scoreEvt then return end
  if now - lastBroadcast < 0.5 then return end
  lastBroadcast = now
  -- broadcast the BEST score (PB), not the current run, so a bust never drops
  -- you off the leaderboard.
  pcall(function() scoreEvt{ score = math.floor(math.max(me.session, me.pb)), combo = me.combo } end)
end

local function pushChat(who, text, kind)
  chatLines[#chatLines+1] = { who=who, text=text, kind=kind or 'user', t=now }
  while #chatLines > 40 do table.remove(chatLines, 1) end
end

-- DRKZ peer-to-peer chat channel: works between DRKZ users on ANY server even
-- if the native chat hooks are missing on this build. Native server chat is
-- still used when available (so you also see non-DRKZ players).
local chatEvt, canNativeSend, canNativeRecv = nil, false, false

local function initChat()
  -- 1) native RECEIVE: try the known hook names, whichever exists
  local recvHook = ac.onChatMessage or ac.onOnlineChat or ac.onClientChat
  if recvHook then
    local ok = pcall(function()
      recvHook(function(message, senderCarIndex)
        local who, kind
        if senderCarIndex == nil or senderCarIndex < 0 then who,kind='Server','sys'
        elseif senderCarIndex == 0 then who,kind=driverName(0),'me'
        else who,kind=driverName(senderCarIndex),'user' end
        pushChat(who, tostring(message), kind)
      end)
    end)
    canNativeRecv = ok
  end

  -- 2) native SEND probe
  canNativeSend = ac.sendChatMessage ~= nil

  -- 3) DRKZ P2P channel (receive text from other DRKZ users)
  if ac.OnlineEvent then
    pcall(function()
      chatEvt = ac.OnlineEvent({
        ac.StructItem.key('DRKZ_UI2_chat'),
        text = ac.StructItem.string(120),
      }, function(sender, data)
        if not sender or sender.index == nil or sender.index < 1 then return end
        pushChat(driverName(sender.index), tostring(data.text), 'user')
      end)
    end)
  end

  ac.log(string.format('[DRKZ] chat: nativeRecv=%s nativeSend=%s p2p=%s',
    tostring(canNativeRecv), tostring(canNativeSend), tostring(chatEvt ~= nil)))
  pushChat('System', 'DRKZ UI 2.0 online. Get close to traffic to score.', 'sys')
end

local function sendChat(text)
  if text == nil or text == '' then return end
  local sent = false
  -- try native server chat first (everyone sees it)
  if canNativeSend then sent = pcall(ac.sendChatMessage, text) end
  -- also push over the DRKZ P2P channel so other DRKZ users always see it
  if chatEvt then pcall(function() chatEvt{ text = text:sub(1,120) } end) end
  -- echo locally so you always see your own line
  pushChat(driverName(0), text, 'me')
  if not sent and not chatEvt then
    pushChat('System', 'No chat channel available on this build.', 'sys')
  end
end

------------------------------------------------------------------------------
-- 5. SCORING
------------------------------------------------------------------------------

local function updateScoring(dt)
  local sim = ac.getSim and ac.getSim() or nil
  local my  = ac.getCar and ac.getCar(0) or nil
  if not sim or not my then return end
  me.kmh = my.speedKmh or 0

  -- ---- scan cars: build the Nearby list AND accumulate proximity gain --------
  nearby = {}
  local gained, closest, humanCount, rawNear = 0, 1e9, 0, 0
  local count = sim.carsCount or 0
  for i = 1, count - 1 do
    local c = ac.getCar(i)
    if c then
      local function cf(name) local ok,v = pcall(function() return c[name] end); if ok then return v end end
      local pos = cf('position')
      local d = (my.position and pos) and my.position:distance(pos) or 1e9
      local atOrigin = pos and math.abs(pos.x) < 1 and math.abs(pos.z) < 1
      if d < PROX_RANGE and d > 0.3 and not atOrigin then
        rawNear = rawNear + 1
        gained = gained + (1 - d / PROX_RANGE)     -- closer = more, off ANY car
        if d < closest then closest = d end

        -- Nearby Drivers list: real HUMAN players only, AI hidden
        local aiFlag = cf('isAIControlled') == true
        local rawOk, rawName = pcall(ac.getDriverName, i)
        rawName = (rawOk and rawName) or ''
        local low = rawName:lower()
        local isTraffic = aiFlag or rawName == '' or low:find('traffic') or low:find('bot') or low:match('^%d+$') ~= nil
        if not isTraffic then
          humanCount = humanCount + 1
          local key = cf('sessionID') or i
          local rs = remote[key]
          nearby[#nearby+1] = { index=i, name=rawName, dist=d, score=rs and rs.score or nil, combo=rs and rs.combo or nil }
        end
      end
    end
  end
  table.sort(nearby, function(a,b) return a.dist < b.dist end)
  me.nearby = humanCount
  me.rawNear = rawNear

  -- must be CRUISING to score (no farming while parked); reward higher speed
  if me.kmh < MIN_CRUISE then gained = 0 end
  gained = gained * math.clamp(me.kmh / 60, 0, 4)
  me.gainRate = gained

  -- display multipliers
  me.speedMul = 1 + math.clamp(me.kmh/50, 0, 20)
  me.proxMul  = 1 + (closest < 1e8 and (1 - math.clamp(closest/PROX_RANGE, 0, 1)) * 4 or 0)
                  + (closest < PROX_CLOSE and 2 or 0)

  -- combo builds over time while scoring, decays when you stop
  if gained > 0 and me.kmh > 15 then me.comboT = math.min(me.comboT + dt, COMBO_MAX)
  else me.comboT = math.max(me.comboT - dt*COMBO_DECAY, 0) end
  me.combo = 1 + me.comboT*COMBO_GAIN

  -- award points continuously (Combo x Prox stacked in)
  if gained > 0 then
    me.session = me.session + gained * dt * BASE_RATE * me.combo * me.proxMul
    if me.session > me.pb then me.pb = me.session; S.pbScore = math.floor(me.pb) end
    S.rankPts = (S.rankPts or 0) + gained * dt * BASE_RATE * 0.02
  end

  -- ---- CRASH: sudden hard deceleration -> lose a life ------------------------
  local drop = prevKmh - me.kmh
  me.lastDrop = drop
  local colDepth = 0
  pcall(function() colDepth = my.collisionDepth or 0 end)
  me.colDepth = colDepth
  local crashed = (prevKmh > 50 and drop > CRASH_DROP) or colDepth > 0.02
  if crashed and now > crashCooldownEnd then
    crashCooldownEnd = now + CRASH_COOLDOWN
    speedoFlashEnd   = now + 0.5           -- red speedo flash for 0.5s
    if me.lives >= 2 then
      -- first crash: lose a life, reset combo, KEEP the points
      me.lives = 1
      me.combo, me.comboT = 1, 0
    else
      -- final life: run ends
      me.session = 0
      me.combo, me.comboT = 1, 0
      me.lives = 2
      vignetteStart, vignetteEnd = now, now + 1.5   -- full-screen red flash
    end
  end
  prevKmh = me.kmh

  broadcastScore()
  for k,v in pairs(remote) do if now - v.t > 8 then remote[k] = nil end end
end

local RANK_STEP = 5e6
local function rankInfo()
  local pts = S.rankPts or 0
  return math.floor(pts/RANK_STEP), (pts % RANK_STEP)/RANK_STEP
end

------------------------------------------------------------------------------
-- 6. DRAW PRIMITIVES  (all window-local: 0,0 = window top-left)
------------------------------------------------------------------------------

-- LIQUID GLASS panels: a real frosted blur of the scene behind, a translucent
-- dark tint on top, a soft outer rim and a bright top-edge sheen so every panel
-- reads like a pane of dark glass. Rounder corners via ROUND.
local ROUND = 1.8
local function plate(p, sz, r, fill, glass)
  r = (r or 12) * ROUND
  local blurred = false
  if canBlur then
    blurred = pcall(function()
      ui.beginBlurring()
      ui.drawRectFilled(p, p+sz, rgbm(1,1,1,1), r)
      ui.endBlurring(1.0)               -- strong frost
    end)
  end
  -- translucent dark tint (more see-through when the blur is available so the
  -- frosted scene shows through = the liquid-glass feel)
  local f = fill
  if not f then
    if glass then f = blurred and rgbm(0.035,0.04,0.055,0.52) or rgbm(0.05,0.055,0.07,0.84)
    else       f = blurred and rgbm(0.04,0.045,0.06,0.62)  or C.plate end
  end
  ui.drawRectFilled(p, p+sz, f, r)
  -- soft outer rim
  ui.drawRect(p, p+sz, rgbm(1,1,1,0.10), r, 1.5)
  -- bright sheen along the very top edge (the glassy highlight)
  ui.drawLine(vec2(p.x + r*0.55, p.y + 1.5), vec2(p.x + sz.x - r*0.55, p.y + 1.5), rgbm(1,1,1,0.13), 1)
end
local function gradientBar(p, sz, stops, r)
  r = r or 8; local n = 56
  for i = 0, n-1 do
    local t0, t1 = i/n, (i+1)/n
    local col = stops[#stops][2]
    for k = 1, #stops-1 do
      if t0 <= stops[k+1][1] then
        local a,b = stops[k], stops[k+1]; local f = (t0-a[1])/math.max(b[1]-a[1],0.0001)
        col = rgbm(math.lerp(a[2].r,b[2].r,f), math.lerp(a[2].g,b[2].g,f), math.lerp(a[2].b,b[2].b,f), 1); break
      end
    end
    local rr = (i==0 or i==n-1) and r or 0
    ui.drawRectFilled(vec2(p.x+sz.x*t0, p.y), vec2(p.x+sz.x*t1+1, p.y+sz.y), col, rr)
  end
end
local function chip(p, s, size, txtCol, bgCol)
  local w = TW(s, size) + 12
  ui.drawRectFilled(p, p+vec2(w, size+7), bgCol or C.chip, 5)
  T(vec2(p.x+6, p.y+3), s, size, txtCol or C.soft); return w+5
end
local function avatar(c, r, col) ui.drawCircleFilled(c, r, col, 24); ui.drawCircle(c, r+1, C.edgeHi, 24, 2) end
local function arc(c, r, frac, col, th)
  local a0, span = math.rad(152), math.rad(236)
  ui.pathClear(); ui.pathArcTo(c, r, a0, a0+span, 48); ui.pathStroke(rgbm(1,1,1,0.06), false, th)
  if frac > 0.001 then ui.pathClear(); ui.pathArcTo(c, r, a0, a0+span*math.clamp(frac,0,1), 48); ui.pathStroke(col, false, th) end
end
local function glyph(kind, c, r, col)
  if kind=='jacket' then
    ui.drawRectFilled(vec2(c.x-r*0.6,c.y-r*0.7), vec2(c.x+r*0.6,c.y+r*0.7), col, 3)
    ui.drawRectFilled(vec2(c.x-r*0.18,c.y-r*0.7), vec2(c.x+r*0.18,c.y+r*0.2), C.greenBg, 1)
  elseif kind=='car' then
    ui.drawRectFilled(vec2(c.x-r*0.8,c.y-r*0.15), vec2(c.x+r*0.8,c.y+r*0.3), col, 2)
    ui.drawRectFilled(vec2(c.x-r*0.45,c.y-r*0.5), vec2(c.x+r*0.45,c.y-r*0.1), col, 2)
  elseif kind=='gear' then
    ui.drawCircle(c, r*0.62, col, 20, 2)
    for i=0,5 do local a=i*math.pi/3; ui.drawLine(vec2(c.x+math.cos(a)*r*0.62,c.y+math.sin(a)*r*0.62), vec2(c.x+math.cos(a)*r,c.y+math.sin(a)*r), col, 2) end
  elseif kind=='heart' then
    ui.drawCircleFilled(vec2(c.x-r*0.35,c.y-r*0.2), r*0.42, col, 14)
    ui.drawCircleFilled(vec2(c.x+r*0.35,c.y-r*0.2), r*0.42, col, 14)
    ui.drawTriangleFilled(vec2(c.x-r*0.78,c.y-r*0.05), vec2(c.x+r*0.78,c.y-r*0.05), vec2(c.x,c.y+r*0.85), col)
  elseif kind=='eye' then ui.drawCircle(c, r*0.7, col, 20, 2); ui.drawCircleFilled(c, r*0.3, col, 12)
  elseif kind=='x' then
    ui.drawLine(vec2(c.x-r*0.5,c.y-r*0.5), vec2(c.x+r*0.5,c.y+r*0.5), col, 1.6)
    ui.drawLine(vec2(c.x+r*0.5,c.y-r*0.5), vec2(c.x-r*0.5,c.y+r*0.5), col, 1.6)
  elseif kind=='radar' then
    ui.drawCircle(c, r*0.8, col, 20, 2); ui.drawCircle(c, r*0.45, col, 16, 1.4)
    ui.drawLine(c, vec2(c.x+r*0.8, c.y-r*0.4), col, 1.6)
  end
end

------------------------------------------------------------------------------
-- 7. PANEL WRAPPER using ui.transparentWindow  +  local mouse helpers
------------------------------------------------------------------------------

local P = {
  pb   = { pos=unpack2(S.pPB),   scale=S.sPB,   sk='sPB',   pk='pPB'   },
  pts  = { pos=unpack2(S.pPts),  scale=S.sPts,  sk='sPts',  pk='pPts'  },
  crew = { pos=unpack2(S.pCrew), scale=S.sCrew, sk='sCrew', pk='pCrew' },
  chat = { pos=unpack2(S.pChat), scale=S.sChat, sk='sChat', pk='pChat' },
  spd  = { pos=unpack2(S.pSpd),  scale=S.sSpd,  sk='sSpd',  pk='pSpd'  },
  stat = { pos=unpack2(S.pStat), scale=S.sStat, sk='sStat', pk='pStat' },
}
local dragging = nil
local curWinPos, curWinSz = vec2(0,0), vec2(0,0)

local function localMouse()
  if ui.mouseLocalPos then local ok, m = pcall(ui.mouseLocalPos); if ok and m then return m end end
  local mp = ui.mousePos and ui.mousePos() or vec2(-1,-1)
  return vec2(mp.x - curWinPos.x, mp.y - curWinPos.y)
end
local function winHovered()
  if ui.windowHovered then local ok, h = pcall(ui.windowHovered); if ok then return h end end
  local m = localMouse()
  return m.x >= 0 and m.x <= curWinSz.x and m.y >= 0 and m.y <= curWinSz.y
end
local function clicked(p, sz)
  local m = localMouse()
  return mouseClicked() and m.x >= p.x and m.x <= p.x+sz.x and m.y >= p.y and m.y <= p.y+sz.y
end
local function hovering(p, sz)
  local m = localMouse()
  return m.x >= p.x and m.x <= p.x+sz.x and m.y >= p.y and m.y <= p.y+sz.y
end

-- makeWindow: a floating, draggable, scroll-resizable panel drawn by `body`
local function panel(id, key, baseW, baseH, body)
  local st = P[key]; local s = st.scale; local sz = vec2(baseW*s, baseH*s)
  ui.transparentWindow('drkz_'..id, st.pos, sz, true, true, function()
    curWinPos, curWinSz = st.pos, sz
    body(vec2(0,0), s, sz)
    if winHovered() then
      local w = mouseWheel(); if w ~= 0 then st.scale = math.clamp(s + w*0.05, 0.5, 2.0) end
      if dragging == nil and mouseDown() then dragging = id end
    end
    if dragging == id then
      if mouseDown() then st.pos = st.pos + mouseDelta() else dragging = nil end
    end
    S[st.pk] = pack2(st.pos); S[st.sk] = st.scale
  end)
end

-- fixedWindow: a non-draggable panel at an exact screen pos (gear, menus)
local function fixedWindow(id, pos, sz, body)
  ui.transparentWindow('drkz_'..id, pos, sz, true, true, function()
    curWinPos, curWinSz = pos, sz
    body(vec2(0,0), sz)
  end)
end

------------------------------------------------------------------------------
-- 8. PB / RANK
------------------------------------------------------------------------------

local function drawPB()
  panel('pb', 'pb', 330, 142, function(p, s)
    local lvl, into = rankInfo()
    local h1 = 46*s
    plate(p, vec2(330*s, h1), 12*s)
    T(vec2(p.x+16*s,p.y+9*s),'PB',13*s,C.white,FONT_B)
    T(vec2(p.x+16*s,p.y+25*s),'SOLO',9*s,C.muted)
    T(vec2(p.x+52*s,p.y+11*s), comma(me.pb), 23*s, C.white, FONT_X)
    TR(vec2(p.x,p.y+16*s), 314*s, '#2,203', 13*s, C.muted)
    local y2 = p.y+h1+6*s; local h2 = 46*s
    plate(vec2(p.x,y2), vec2(330*s,h2), 12*s)
    ui.drawRectFilled(vec2(p.x+7*s,y2+7*s), vec2(p.x+41*s,y2+39*s), C.greenBg, 8*s)
    glyph('jacket', vec2(p.x+24*s,y2+23*s), 10*s, C.greenIco)
    local bx, bw = p.x+50*s, 273*s
    ui.drawRectFilled(vec2(bx,y2+8*s), vec2(bx+bw,y2+38*s), C.slot, 8*s)
    gradientBar(vec2(bx,y2+8*s), vec2(bw*math.max(into,0.04),30*s), {{0,C.greenA},{1,C.greenB}}, 8*s)
    T(vec2(bx+14*s,y2+15*s), 'Licenced '..lvl, 15*s, C.inkGreen, FONT_B)
    local y3 = y2+h2+6*s; local h3 = 32*s
    plate(vec2(p.x,y3), vec2(330*s,h3), 10*s)
    T(vec2(p.x+14*s,y3+9*s),'Sanctioned',12*s,C.muted)
    TR(vec2(p.x,y3+9*s), 250*s, 'Next Rank', 12*s, C.muted)
    local function dot(cx,n) ui.drawCircleFilled(vec2(cx,y3+16*s),9*s,hex('2B2F38'),16); TC(vec2(cx-9*s,y3+10*s),18*s,n,10*s,hex('E8E8EE'),FONT_B) end
    dot(p.x+268*s, tostring(lvl)); TC(vec2(p.x+280*s,y3+10*s),22*s,'>>>',10*s,hex('6A6F79')); dot(p.x+312*s, tostring(lvl+1))
  end)
end

------------------------------------------------------------------------------
-- 9. POINTS
------------------------------------------------------------------------------

local function drawPoints()
  panel('pts', 'pts', 424, 122, function(p, s)
    local h1 = 56*s
    plate(p, vec2(390*s,h1), 12*s)
    local function stat(x,w,big,small,col) TC(vec2(p.x+x,p.y+10*s),w,big,19*s,col or C.white,FONT_X); TC(vec2(p.x+x,p.y+34*s),w,small,11*s,C.muted) end
    stat(8*s,92*s, string.format('%.1fX',me.combo),'Combo')
    stat(100*s,92*s, string.format('%.1fX',me.speedMul),'Speed',C.white)
    stat(192*s,92*s, string.format('%.1fX',me.proxMul),'Prox')
    -- top-right block: total multiplier + the 2 life dots
    ui.drawRectFilled(vec2(p.x+292*s,p.y+8*s), vec2(p.x+382*s,p.y+40*s), C.grayBox, 9*s)
    TC(vec2(p.x+292*s,p.y+13*s),90*s, string.format('%.1fX', me.combo), 16*s, C.white, FONT_X)
    -- LIVES: two dots (filled = life remaining, dim = lost)
    for i=0,1 do
      local lc = vec2(p.x+(312+i*24)*s, p.y+48*s)
      ui.drawCircleFilled(lc, 5*s, i < me.lives and C.hp or rgbm(0.30,0.10,0.10,0.9), 14)
      ui.drawCircle(lc, 5*s, rgbm(1,1,1,0.15), 14, 1)
    end

    local y2 = p.y+h1+8*s
    plate(vec2(p.x,y2), vec2(390*s,54*s), 12*s)
    local bx,by,bw,bh = p.x+7*s, y2+7*s, 376*s, 40*s
    ui.drawRectFilled(vec2(bx,by), vec2(bx+bw,by+bh), C.barWhite, bh/2)
    local ins = 3*s
    local ih  = bh - ins*2
    local fill = math.clamp(me.session/math.max(me.pb,1), 0.04, 1)
    local fw = math.max((bw-ins*2)*fill, ih)   -- keep a full pill even when tiny
    ui.drawRectFilled(vec2(bx+ins,by+ins), vec2(bx+ins+fw, by+ins+ih), C.purpB, ih/2)
    TC(vec2(bx,by+10*s), bw, comma(me.session)..' PTS', 20*s, C.ink, FONT_X)
  end)
end

------------------------------------------------------------------------------
-- 10. NEARBY DRIVERS
------------------------------------------------------------------------------

local function drawNearby()
  if not S.showCrew then return end
  panel('crew', 'crew', 348, 396, function(p, s)
    plate(p, vec2(348*s,396*s), 14*s)
    T(vec2(p.x+16*s,p.y+14*s), 'Nearby Drivers '..me.nearby, 15*s, hex('D6D6DC'))
    glyph('radar', vec2(p.x+322*s,p.y+22*s), 8*s, me.nearby>0 and C.hp or C.muted)
    if clicked(vec2(p.x+310*s,p.y+10*s), vec2(28*s,24*s)) then S.showCrew = false end
    if #nearby == 0 then
      TC(vec2(p.x,p.y+170*s),348*s,'No players nearby',13*s,C.muted)
      TC(vec2(p.x,p.y+192*s),348*s,'Drive close to traffic to score',11*s,C.faint)
    else
      for i=1, math.min(#nearby,4) do
        local m = nearby[i]; local ry = p.y+(44+(i-1)*78)*s
        local rp = vec2(p.x+12*s,ry); local rsz = vec2(324*s,68*s)
        ui.drawRectFilled(rp, rp+rsz, C.plateSub, 13*s); ui.drawRect(rp, rp+rsz, C.edge, 13*s, 1)
        local closeF = 1 - math.clamp(m.dist/PROX_RANGE,0,1)
        avatar(vec2(rp.x+37*s,ry+34*s), 24*s, rgbm(0.23+closeF*0.1, 0.55*closeF+0.2, 0.35, 1))
        T(vec2(rp.x+70*s,ry+11*s), m.score and comma(m.score) or m.name, 20*s, C.white, FONT_X)
        T(vec2(rp.x+70*s,ry+40*s), m.name, 13*s, hex('9A9AA4'))
        local bx = rp.x+196*s
        ui.drawRectFilled(vec2(bx,ry+16*s), vec2(bx+44*s,ry+52*s), m.dist<PROX_CLOSE and rgbm(0.94,0.39,0.12,0.25) or rgbm(1,1,1,0.05), 10*s)
        TC(vec2(bx,ry+22*s),44*s, string.format('%.0f',m.dist), 15*s, C.white, FONT_B)
        TC(vec2(bx,ry+39*s),44*s,'m',9*s,C.muted)
        glyph('car', vec2(rp.x+288*s,ry+24*s), 9*s, hex('9A9AA4'))
        TC(vec2(rp.x+272*s,ry+38*s),32*s, m.combo and string.format('%.0fX',m.combo) or '-', 12*s, C.pink, FONT_B)
      end
    end
    local fy = p.y+358*s
    ui.drawCircleFilled(vec2(p.x+27*s,fy+11*s), 11*s, rgbm(0.94,0.55,0.12,0.18), 16)
    T(vec2(p.x+23*s,fy+4*s),'S',12*s,C.orange,FONT_B)
    T(vec2(p.x+44*s,fy+4*s),'Scroll to resize',12*s,hex('D6D6DC'))
    T(vec2(p.x+142*s,fy+4*s), string.format('%.0f%%',s*100), 12*s, C.white, FONT_B)
    ui.drawCircleFilled(vec2(p.x+196*s,fy+11*s), 11*s, rgbm(0.66,0.33,0.97,0.18), 16)
    T(vec2(p.x+192*s,fy+4*s),'H',12*s,C.purple,FONT_B)
    T(vec2(p.x+214*s,fy+4*s),'Hold to move',12*s,hex('D6D6DC'))
  end)
end

------------------------------------------------------------------------------
-- 11. CHAT
------------------------------------------------------------------------------

local function drawChat()
  if not S.showChat then return end
  panel('chat', 'chat', 470, 590, function(p, s)
    plate(p, vec2(470*s,590*s), 18*s)   -- same clean dark glass as the rest of the HUD
    T(vec2(p.x+16*s,p.y+14*s),'Chat',15*s,hex('D6D6DC'))
    glyph('gear', vec2(p.x+390*s,p.y+22*s),7*s,C.muted)
    ui.drawLine(vec2(p.x+414*s,p.y+22*s), vec2(p.x+426*s,p.y+22*s), C.muted, 1.6)
    glyph('x', vec2(p.x+446*s,p.y+22*s),7*s,C.muted)
    if clicked(vec2(p.x+436*s,p.y+10*s), vec2(24*s,24*s)) then S.showChat = false end
    local top, bottom, lineH = p.y+44*s, p.y+484*s, 40*s
    local maxLines = math.max(1, math.floor((bottom-top)/lineH))
    local startIdx = math.max(1, #chatLines - maxLines + 1)
    local y = top
    for i = startIdx, #chatLines do
      local m = chatLines[i]
      local nameCol = C.soft
      if m.kind=='sys' then nameCol=C.sys elseif m.kind=='me' then nameCol=C.pink elseif m.kind=='whisper' then nameCol=C.nPurple end
      avatar(vec2(p.x+30*s,y+12*s), 13*s, m.kind=='sys' and hex('2B3A2F') or hex('4A5568'))
      T(vec2(p.x+52*s,y), m.who, 13*s, nameCol, FONT_B)
      T(vec2(p.x+52*s,y+17*s), m.text, 12*s, (m.kind=='sys') and C.muted or C.soft)
      y = y + lineH
    end
    if me.nearby > 0 then
      local label = me.nearby..' driver'..(me.nearby>1 and 's' or '')..' nearby'
      local tw = TW(label,12*s)+28*s
      local tp = vec2(p.x+148*s,p.y+462*s)
      ui.drawRectFilled(tp, tp+vec2(tw,24*s), rgbm(0.15,0.16,0.19,0.92), 8*s)
      T(vec2(tp.x+14*s,tp.y+5*s), label, 12*s, C.soft)
    end
    local iy = p.y+494*s
    ui.drawRectFilled(vec2(p.x+12*s,iy), vec2(p.x+458*s,iy+80*s), rgbm(0.10,0.11,0.13,0.9), 11*s)
    ui.drawRect(vec2(p.x+12*s,iy), vec2(p.x+458*s,iy+80*s), C.edge, 11*s, 1)
    ui.drawLine(vec2(p.x+12*s,iy+36*s), vec2(p.x+458*s,iy+36*s), C.edge, 1)
    T(vec2(p.x+26*s,iy+10*s),'Send to',12*s,C.soft)
    T(vec2(p.x+78*s,iy+10*s), 'All', 12*s, C.white, FONT_B)
    -- real input field. ui.inputText returns text + an "entered" bool, but the
    -- ORDER varies between builds, so sort them out by type (never send a bool).
    ui.setCursor(vec2(24, (iy-p.y)+44))
    ui.pushItemWidth(360*s)
    local ok, r1, r2 = pcall(function() return ui.inputText('Message to All##drkzChat', chatDraft, ui.InputTextFlags.EnterReturnsTrue) end)
    ui.popItemWidth()
    if ok then
      local newText, entered
      if type(r1) == 'string' then newText, entered = r1, (r2 == true)
      elseif type(r2) == 'string' then newText, entered = r2, (r1 == true)
      else newText, entered = chatDraft, false end
      chatDraft = newText
      if entered and chatDraft ~= '' then sendChat(chatDraft); chatDraft = '' end
    end
  end)
end

------------------------------------------------------------------------------
-- 12. SPEEDO
------------------------------------------------------------------------------

-- shift-light colour by rpm fraction: green (cruise) -> yellow -> red (redline)
local function shiftColor(f)
  if f < 0.85 then return C.hp
  elseif f < 0.94 then return hex('F5D020')
  else return hex('FF3B3B') end
end

local function drawSpeedo()
  if not S.showSpeedo then return end
  local car = ac.getCar and ac.getCar(0) or nil
  local gear, rpm, rpmMax, kmh, fuel = 0, 0, 8000, 0, 0
  if car then
    gear=car.gear; rpm=car.rpm; rpmMax=(car.rpmLimiter and car.rpmLimiter>0) and car.rpmLimiter or 8000
    kmh=car.speedKmh; fuel=car.fuel or 0
  end
  local gtxt = gear==-1 and 'R' or (gear==0 and 'N' or tostring(gear))
  local f = math.clamp(rpm/rpmMax, 0, 1)
  local col = shiftColor(f)

  -- single-pill layout matching the reference: gear ring on the left, shift
  -- dots across the top, KMH + RPM side by side, fuel/est-lap bar underneath.
  panel('spd', 'spd', 440, 150, function(p, s)
    -- capsule background
    plate(p, vec2(440*s, 150*s), 30*s)
    -- crash flash: red border + wash for 0.5s after losing a life
    if now < speedoFlashEnd then
      local a = math.clamp((speedoFlashEnd - now) / 0.5, 0, 1)
      ui.drawRectFilled(p, p + vec2(440*s,150*s), rgbm(0.9,0.05,0.05, 0.35*a), 30*s)
      ui.drawRect(p, p + vec2(440*s,150*s), rgbm(1,0.15,0.15, a), 30*s, 4*s)
    end

    -- left: gear inside a colour-changing rpm ring
    local lc = vec2(p.x+70*s, p.y+72*s)
    local a0, span = math.rad(138), math.rad(264)
    ui.pathClear(); ui.pathArcTo(lc, 46*s, a0, a0+span, 44); ui.pathStroke(rgbm(1,1,1,0.08), false, 8*s)
    if f > 0.01 then ui.pathClear(); ui.pathArcTo(lc, 46*s, a0, a0+span*f, 44); ui.pathStroke(col, false, 8*s) end
    TC(vec2(lc.x-34*s, lc.y-28*s), 68*s, gtxt, 46*s, C.white, FONT_X)

    -- top: shift-light dot row, fills with rpm, tinted by the shift colour
    local dots = 16
    local lit = math.floor(f * dots + 0.001)
    for i=0, dots-1 do
      local dc = vec2(p.x+(150+i*16)*s, p.y+34*s)
      ui.drawCircleFilled(dc, 4*s, i < lit and col or hex('3A3D46'), 12)
    end

    -- centre: KMH and RPM, labels then big numbers, left-aligned like the pic
    T(vec2(p.x+150*s, p.y+62*s), 'KMH', 13*s, C.muted, FONT_B)
    T(vec2(p.x+150*s, p.y+78*s), string.format('%.0f', kmh), 40*s, C.white, FONT_X)
    T(vec2(p.x+300*s, p.y+62*s), 'RPM', 13*s, C.muted, FONT_B)
    T(vec2(p.x+300*s, p.y+78*s), string.format('%.0f', rpm), 40*s, C.white, FONT_X)

    -- bottom: fuel + est-lap pill
    local ap = vec2(p.x+142*s, p.y+124*s)
    ui.drawRectFilled(ap, ap+vec2(286*s, 22*s), rgbm(1,1,1,0.05), 11*s)
    ui.drawRect(ap, ap+vec2(286*s, 22*s), C.edge, 11*s, 1)
    ui.drawCircleFilled(vec2(ap.x+16*s, ap.y+11*s), 4*s, C.muted, 12)
    T(vec2(ap.x+28*s, ap.y+4*s), 'FUEL', 12*s, C.muted, FONT_B)
    T(vec2(ap.x+66*s, ap.y+4*s), string.format('%.1fL', fuel), 12*s, C.white, FONT_B)
    T(vec2(ap.x+150*s, ap.y+4*s), 'EST. LAP', 12*s, C.muted, FONT_B)
    T(vec2(ap.x+218*s, ap.y+4*s), '-', 12*s, C.white, FONT_B)
  end)
end

------------------------------------------------------------------------------
-- 13. STATUS STRIP
------------------------------------------------------------------------------

local function drawStatus()
  panel('stat', 'stat', 430, 24, function(p, s)
    glyph('eye', vec2(p.x+8*s,p.y+11*s), 6*s, C.muted)
    T(vec2(p.x+20*s,p.y+4*s),'Aggro Multiplier',12*s,hex('D6D6DC'))
    local seg = math.clamp(math.floor(me.proxMul),0,5)
    for i=0,4 do ui.drawRectFilled(vec2(p.x+(122+i*19)*s,p.y+7*s), vec2(p.x+(139+i*19)*s,p.y+15*s), i<seg and C.orange or C.off, 2*s) end
    glyph('car', vec2(p.x+232*s,p.y+11*s), 6*s, C.muted)
    T(vec2(p.x+244*s,p.y+4*s),'Physics bonus',12*s,hex('D6D6DC'))
    ui.drawRectFilled(vec2(p.x+330*s,p.y+7*s), vec2(p.x+339*s,p.y+16*s), me.kmh>40 and C.hp or C.off, 2*s)
    glyph('eye', vec2(p.x+356*s,p.y+11*s), 6*s, C.muted)
    T(vec2(p.x+368*s,p.y+4*s),'FPV Bonus',12*s,hex('D6D6DC'))
    ui.drawRect(vec2(p.x+434*s,p.y+7*s), vec2(p.x+443*s,p.y+16*s), hex('5A5D66'), 2*s, 1)
  end)
end

------------------------------------------------------------------------------
-- 14. GEAR + QUICK ACTIONS + PAINT + LEADERBOARD
------------------------------------------------------------------------------

local showQuickActions, showPaintEditor, showLeaderboard = false, false, false

local function drawGear()
  local sw = screenSize(); local sz = 36; local pos = vec2(sw.x-sz-14, 14)
  fixedWindow('gear', pos, vec2(sz,sz), function(p, w)
    plate(p, vec2(sz,sz), 10)
    glyph('gear', vec2(p.x+sz/2,p.y+sz/2), 10, showQuickActions and C.pink or C.white)
    if clicked(p, vec2(sz,sz)) then showQuickActions = not showQuickActions end
  end)
end

local qaCards = { {'Nearby','showCrew'}, {'Toggle UI','showUI'}, {'Speedometer','showSpeedo'}, {'Chat','showChat'} }
local qaNav = { 'Nearby Drivers', 'Change Car Color', 'Leaderboard', 'Reset Session', 'UI Settings' }

local function drawQuickActions()
  if not showQuickActions then return end
  local sw = screenSize(); local W, H = 222, 340; local pos = vec2(sw.x-W-14, 60)
  fixedWindow('quick', pos, vec2(W,H), function(p, w)
    plate(p, vec2(W,H), 13)
    T(vec2(p.x+13,p.y+12),'QUICK ACTIONS',10,C.muted)
    for i,c in ipairs(qaCards) do
      local cp = vec2(p.x+13+((i-1)%2)*100, p.y+30+math.floor((i-1)/2)*58); local cs = vec2(92,50)
      ui.drawRectFilled(cp, cp+cs, rgbm(1,1,1,0.06), 9)
      ui.drawCircleFilled(vec2(cp.x+cs.x-12,cp.y+12), 4.5, S[c[2]] and C.hp or C.off, 12)
      T(vec2(cp.x+9,cp.y+28), c[1], 11, C.soft)
      if clicked(cp, cs) then S[c[2]] = not S[c[2]] end
    end
    local ny = p.y+150
    for _,label in ipairs(qaNav) do
      local rp, rs = vec2(p.x+8,ny), vec2(W-16,34)
      if hovering(rp, rs) then ui.drawRectFilled(rp, rp+rs, rgbm(1,1,1,0.07), 8) end
      T(vec2(rp.x+10,rp.y+9), label, 12, C.soft)
      if clicked(rp, rs) then
        if label=='Change Car Color' then showPaintEditor=true
        elseif label=='Leaderboard' then showLeaderboard = not showLeaderboard
        elseif label=='Nearby Drivers' then S.showCrew = not S.showCrew
        elseif label=='Reset Session' then me.session=0; me.comboT=0; me.combo=1
        elseif label=='UI Settings' then S.showCrew=true; S.showChat=true; S.showSpeedo=true end
      end
      ny = ny + 37
    end
  end)
end

local paint = { tab='Body', part='ALL BODY', color=rgbm(0.043,0.114,0.278,1), metallic=0.5, sharp=0.5, clear=0.5, backlt=0.5 }
local paintTabs = { 'Body','Wheels','Interior' }
local paintParts = { 'ALL BODY','DOORS','FRONT BUMPER','TRUNK','REAR BUMPER','HOOD' }
-- Live recolour of the player's car body. AC has no single "set colour" call:
-- you have to find the body meshes and override their material colour. Which
-- material a car uses varies, so we try several common paint-material filters
-- and tint whatever matches. Guarded, so unsupported cars just don't change.
-- We TINT the material colour (ksDiffuse) only - we do NOT replace the texture,
-- so the car keeps all its detail and just changes colour (that was the "whole
-- texture" problem). Each tab targets a different mesh selection; unknown filter
-- syntax is caught and the Body tab falls back to the exterior (minus glass).
local paintFilters = {
  Body     = '{ ! material:DAMAGE_GLASS & lod:A }',
  Wheels   = 'WHEEL_?',
  Interior = 'COCKPIT_HR',
}
local function findSel(carNode, filter)
  local sel
  pcall(function() sel = carNode:findMeshes(filter) end)
  local n = 0
  if sel then pcall(function() n = sel:size() end) end
  return sel, (n or 0)
end
local paintOK, paintMeshes = nil, 0
local _paintNamesLogged = false
local function applyPaint()
  local c3 = rgb(paint.color.r, paint.color.g, paint.color.b)
  local matched, cnt = false, 0
  pcall(function()
    local carNode = ac.findNodes and ac.findNodes('carRoot:0')
    if not carNode or not carNode.findMeshes then return end
    local sel, n = findSel(carNode, paintFilters[paint.tab] or paintFilters.Body)
    -- fallback for Body if the filter matched nothing on an odd car
    if n == 0 and paint.tab == 'Body' then sel, n = findSel(carNode, '{ lod:A }') end
    cnt = n
    if sel and n > 0 then
      pcall(function() sel:setMaterialProperty('ksDiffuse', c3) end)
      matched = true
      if not _paintNamesLogged then
        _paintNamesLogged = true
        pcall(function()
          local names = {}
          for i = 0, math.min(n, 12) - 1 do names[#names+1] = tostring(sel:materialName(i)) end
          ac.log('[DRKZ] '..paint.tab..' materials: ' .. table.concat(names, ', '))
        end)
      end
    end
  end)
  paintOK, paintMeshes = matched, cnt
  S.bodyHex = string.format('#%02X%02X%02X', math.floor(paint.color.r*255), math.floor(paint.color.g*255), math.floor(paint.color.b*255))
end
local function drawPaintEditor()
  if not showPaintEditor then return end
  local sw = screenSize(); local pos = vec2(sw.x/2-200, sw.y/2-175)
  fixedWindow('paint', pos, vec2(400,350), function(p, w)
    plate(p, vec2(400,350), 14)
    T(vec2(p.x+16,p.y+13),'Pick New Color',14,C.white,FONT_B)
    glyph('x', vec2(p.x+380,p.y+20),7,C.muted)
    if clicked(vec2(p.x+368,p.y+8), vec2(24,24)) then showPaintEditor=false end
    local tx = p.x+14
    for _,t in ipairs(paintTabs) do
      local ww, active = 120, paint.tab==t
      ui.drawRectFilled(vec2(tx,p.y+36), vec2(tx+ww,p.y+62), active and C.purple or rgbm(1,1,1,0.06), 7)
      TC(vec2(tx,p.y+42),ww,t,12, active and C.white or C.soft, active and FONT_B or FONT_R)
      if clicked(vec2(tx,p.y+36), vec2(ww,26)) then paint.tab=t end
      tx = tx+ww+6
    end
    local px, py = p.x+14, p.y+70
    for _,pt in ipairs(paintParts) do
      local ww = TW(pt,9)+16
      if px+ww > p.x+386 then px=p.x+14; py=py+24 end
      local active = paint.part==pt
      ui.drawRectFilled(vec2(px,py), vec2(px+ww,py+20), active and C.purple or rgbm(1,1,1,0.06), 5)
      T(vec2(px+8,py+4), pt, 9, active and C.white or C.muted)
      if clicked(vec2(px,py), vec2(ww,20)) then paint.part=pt end
      px = px+ww+5
    end
    -- return one of the picker's outputs that is actually a colour (has .r),
    -- never a boolean - that was corrupting paint.color and killing the picker.
    local function asColor(x)
      local okc, r = pcall(function() return x.r end)
      if okc and type(r) == 'number' then return x end
      return nil
    end
    ui.setCursor(vec2(16, (py-p.y)+32)); ui.pushItemWidth(150)
    local ok, r1, r2 = pcall(function() return ui.colorPicker('##drkzBody', paint.color) end)
    ui.popItemWidth()
    if ok then local nc = asColor(r1) or asColor(r2); if nc then paint.color = nc end end

    T(vec2(p.x+176, py+32),'Material Shading',12,C.white,FONT_B)
    local sy = (py-p.y)+56
    local function slider(label, field)
      ui.setCursor(vec2(176, sy)); ui.pushItemWidth(200)
      local ok2, a, b = pcall(function() return ui.slider('##drkz'..field, math.floor(paint[field]*100), 0, 100, label..': %.0f%%') end)
      ui.popItemWidth()
      if ok2 then
        local val = type(a) == 'number' and a or (type(b) == 'number' and b or nil)
        if val then paint[field] = val/100 end
      end
      sy = sy+30
    end
    slider('Metallic','metallic'); slider('Sharpness','sharp'); slider('Clear Coat','clear'); slider('Backlights','backlt')

    -- repaint only when the colour actually changed (findMeshes is expensive)
    if paint._lr ~= paint.color.r or paint._lg ~= paint.color.g or paint._lb ~= paint.color.b then
      paint._lr, paint._lg, paint._lb = paint.color.r, paint.color.g, paint.color.b
      applyPaint()
    end
    T(vec2(p.x+16,p.y+290), string.format('R:%d  G:%d  B:%d   %s', math.floor(paint.color.r*255), math.floor(paint.color.g*255), math.floor(paint.color.b*255), S.bodyHex), 10, C.muted)
    -- feedback: did we find body meshes to recolour on this car?
    local st = paintOK == nil and 'pick a colour to apply'
      or (paintOK and ('applied to '..paintMeshes..' meshes') or 'could not find car meshes')
    T(vec2(p.x+16,p.y+306), st, 10, paintOK == false and hex('FF6B6B') or C.muted)
    ui.setCursor(vec2(292, 306))
    local okb, pressed = pcall(function() return ui.button('CONFIRM##drkzPaint', vec2(92,28)) end)
    if okb and pressed then applyPaint(); showPaintEditor=false end
  end)
end

local function drawLeaderboard()
  if not showLeaderboard then return end
  fixedWindow('lb', vec2(60,620), vec2(320,260), function(p, w)
    plate(p, vec2(320,260), 14)
    T(vec2(p.x+16,p.y+13),'Live Leaderboard',14,C.white,FONT_B)
    glyph('x', vec2(p.x+300,p.y+20),7,C.muted)
    if clicked(vec2(p.x+288,p.y+8), vec2(24,24)) then showLeaderboard=false end
    local list = { { name=driverName(0)..' (you)', score=math.max(me.session, me.pb), mine=true } }
    for _,v in pairs(remote) do list[#list+1] = { name=v.name, score=v.score } end
    table.sort(list, function(a,b) return a.score > b.score end)
    local y = p.y+44
    for i=1, math.min(#list,6) do
      local m = list[i]
      T(vec2(p.x+16,y), string.format('%d.',i), 13, C.muted)
      T(vec2(p.x+42,y), m.name, 13, m.mine and C.pink or C.white, m.mine and FONT_B or FONT_R)
      TR(vec2(p.x,y),304, comma(m.score), 13, C.purple, FONT_B)
      y = y+32
    end
    if #list==1 then TC(vec2(p.x,p.y+130),320,'Other DRKZ users appear here',11,C.faint) end
  end)
end

------------------------------------------------------------------------------
-- 14b. CRASH FULL-SCREEN FLASH  (final-life run-over vignette)
------------------------------------------------------------------------------

local function drawCrashFx()
  if now >= vignetteEnd then return end
  local sw = screenSize()
  local a = math.clamp((vignetteEnd - now) / 1.5, 0, 1)   -- 1 -> 0 over 1.5s
  ui.transparentWindow('drkz_vignette', vec2(0,0), sw, true, false, function()
    -- ONLY a soft red glow in the corners (no full-screen fill, no text).
    -- Each corner is built from a few nested, fading rectangles.
    local cs = math.min(sw.x, sw.y) * 0.16      -- corner reach
    local steps = 5
    for i = 1, steps do
      local f = i / steps                        -- 0..1 outward
      local col = rgbm(0.85, 0.0, 0.0, 0.10 * a * f)
      local s = cs * f
      -- top-left
      ui.drawRectFilled(vec2(0,0), vec2(s, s), col, 0)
      -- top-right
      ui.drawRectFilled(vec2(sw.x - s, 0), vec2(sw.x, s), col, 0)
      -- bottom-left
      ui.drawRectFilled(vec2(0, sw.y - s), vec2(s, sw.y), col, 0)
      -- bottom-right
      ui.drawRectFilled(vec2(sw.x - s, sw.y - s), sw, col, 0)
    end
  end)
end

------------------------------------------------------------------------------
-- 15. FIRST-RUN LAYOUT + INIT
------------------------------------------------------------------------------

local laidOut, inited = false, false
local function firstRunLayout()
  if laidOut then return end
  local sw = screenSize(); if sw.x < 100 then return end
  laidOut = true
  if S.pPts  == '1240,40'  then P.pts.pos  = vec2(sw.x-470, 40) end
  if S.pChat == '1440,205' then P.chat.pos = vec2(sw.x-486, 205) end
  if S.pSpd  == '1520,860' then P.spd.pos  = vec2(sw.x-470, sw.y-180) end
  if S.pStat == '8,1040'   then P.stat.pos = vec2(14, sw.y-40) end
end

------------------------------------------------------------------------------
-- (old app callback header removed - see online entry points below)
------------------------------------------------------------------------------

local lastError = nil

------------------------------------------------------------------------------
-- 16. ONLINE-SCRIPT ENTRY POINTS
--     This file is delivered BY THE SERVER (CSP extra options -> [SCRIPT_0]).
--     It runs automatically on every connected client - no app install.
--       script.update(dt) : per-frame logic (scoring, networking)
--       script.drawUI()   : per-frame fullscreen HUD drawing
------------------------------------------------------------------------------

local firstLog = false

function script.update(dt)
  if not firstLog then firstLog = true; ac.log('[DRKZ] online script running') end
  if not dt or dt <= 0 then local sim = ac.getSim and ac.getSim() or nil; dt = (sim and sim.dt) or 0.016 end
  now = now + dt
  pcall(function()
    if not inited then inited = true; initNet(); initChat() end
    updateScoring(dt)
  end)
end

function script.drawUI()
  firstRunLayout()
  ui.pushStyleVar(ui.StyleVar.WindowRounding, 12)
  ui.pushStyleVar(ui.StyleVar.FrameRounding, 8)

  local ok, err = pcall(function()
    drawGear()
    if S.showUI then
      drawPB(); drawPoints(); drawNearby(); drawChat(); drawSpeedo(); drawStatus(); drawLeaderboard()
    end
    drawQuickActions(); drawPaintEditor()
    drawCrashFx()          -- full-screen red flash, drawn on top of everything
  end)

  ui.popStyleVar(2)

  if not ok then
    lastError = tostring(err)
    ac.log('[DRKZ] HUD error: ' .. lastError)
    pcall(function()
      ui.transparentWindow('drkz_err', vec2(20, 20), vec2(560, 70), true, false, function()
        ui.drawRectFilled(vec2(0,0), vec2(560,70), rgbm(0.3,0.02,0.02,0.9), 8)
        T(vec2(12,10), 'DRKZ error:', 14, rgbm(1,0.7,0.7,1), FONT_B)
        T(vec2(12,34), lastError:sub(1,90), 12, rgbm(1,0.9,0.9,1))
      end)
    end)
  end
end

--[[ DELIVERY (server-pushed, no client install):
     1. Host this file at a RAW web URL (GitHub raw link or a gist raw link).
     2. In the server's CSP extra options (csp_extra_options.ini) add:
          [SCRIPT_0]
          SCRIPT = 'https://raw.githubusercontent.com/.../drkz_online.lua'
          REQUIRED = 0
     3. Restart the server. Every player with CSP auto-runs the HUD on join.
     Gear button (top-right) opens Quick Actions; there is no app window. ]]--
