--[[
pagenotes.koplugin
Text notes and stickers drawn on top of the page.

How notes stay put:
  In EPUB-type books every note is tied to a word (an "xpointer", the same
  thing KOReader uses for highlights). When the font size changes and the
  word moves to another page, the note follows it.
  In PDF-type books a note is tied to a page number instead.

Note fields (saved in the book's .sdr file):
  id      unique string
  kind    "text" or "sticker"
  text, font, size, align, width (fraction of screen width), bg (white box?)
  sticker "packname/file.png", w (fraction of screen width)
  angle   0..345 in 15 degree steps
  anchor  { type="word", pos0, pos1, dx, dy }        dx/dy = offset from word box, fraction of screen
          { type="page", xp, dx, dy }                 page top xpointer + fraction of screen
          { type="pdfpage", page, dx, dy }
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local FontList = require("fontlist")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MovableContainer = require("ui/widget/container/movablecontainer")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local ROTATE_STEP = 15
local NUDGE = 4        -- pixels per arrow tap in edit mode
local MIN_GRAB = 48    -- smallest touch target for a note, in pixels

-- ---------------------------------------------------------------------
-- Pixel helpers
-- ---------------------------------------------------------------------

-- Copy any blitbuffer into a colour buffer with an alpha channel.
-- If white_is_clear is true, near-white pixels become see-through.
local function toRGBA(src, white_is_clear)
    local w, h = src:getWidth(), src:getHeight()
    local dst = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local c = src:getPixel(x, y):getColorRGB32()
            local a = 255
            if white_is_clear and c.r > 235 and c.g > 235 and c.b > 235 then
                a = 0
            elseif src:getType() == Blitbuffer.TYPE_BBRGB32 then
                a = c.alpha
            end
            dst:setPixel(x, y, Blitbuffer.ColorRGB32(c.r, c.g, c.b, a))
        end
    end
    return dst
end

-- Sticker clean-up, in two separate steps:
--   1. Alpha (how solid a pixel is) snaps to full, half, or a third.
--      Anything fainter than a third is dropped. E-ink cannot show a
--      "slightly there" pixel, it turns it into speckles.
--   2. Tone: the pixel's grey value snaps to one of four tones. White
--      stays white. It is not turned clear.
--   alpha 0..255 (255 = solid)  ->  alpha
local STICKER_ALPHA = {
    { atleast = 190, alpha = 255 },   -- solid
    { atleast = 105, alpha = 128 },   -- half
    { atleast = 64,  alpha = 85 },    -- a third
    -- fainter than 64: dropped
}
--   grey value 0..255 (0 = black)  ->  tone
local STICKER_TONES = {
    { upto = 35,  grey = 0 },      -- black
    { upto = 105, grey = 70 },     -- dark grey
    { upto = 170, grey = 140 },    -- mid grey
    { upto = 225, grey = 200 },    -- light grey
    { upto = 255, grey = 255 },    -- white stays white
}
local function cleanSticker(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local clear = Blitbuffer.ColorRGB32(255, 255, 255, 0)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local c = bb:getPixel(x, y):getColorRGB32()
            local out = clear
            local a = 0
            for _, t in ipairs(STICKER_ALPHA) do
                if c.alpha >= t.atleast then a = t.alpha break end
            end
            if a > 0 then
                local grey = (c.r * 299 + c.g * 587 + c.b * 114) / 1000
                for _, t in ipairs(STICKER_TONES) do
                    if grey <= t.upto then
                        out = Blitbuffer.ColorRGB32(t.grey, t.grey, t.grey, a)
                        break
                    end
                end
            end
            bb:setPixel(x, y, out)
        end
    end
end

-- Rotate an RGBA buffer by any angle (degrees). Returns a new buffer big
-- enough to hold the rotated picture. Done pixel by pixel, so keep
-- pictures small-ish.
local function rotateRGBA(src, deg)
    local rad = math.rad(deg)
    local cs, sn = math.cos(rad), math.sin(rad)
    local w, h = src:getWidth(), src:getHeight()
    local nw = math.ceil(math.abs(w * cs) + math.abs(h * sn))
    local nh = math.ceil(math.abs(w * sn) + math.abs(h * cs))
    local dst = Blitbuffer.new(nw, nh, Blitbuffer.TYPE_BBRGB32)
    -- fill() does not always keep alpha, so every empty pixel is set by hand
    local clear = Blitbuffer.ColorRGB32(255, 255, 255, 0)
    local cx, cy = w / 2, h / 2
    local ncx, ncy = nw / 2, nh / 2
    for y = 0, nh - 1 do
        local dy = y + 0.5 - ncy
        for x = 0, nw - 1 do
            local dx = x + 0.5 - ncx
            local sx = math.floor(dx * cs + dy * sn + cx)
            local sy = math.floor(-dx * sn + dy * cs + cy)
            if sx >= 0 and sx < w and sy >= 0 and sy < h then
                dst:setPixel(x, y, src:getPixel(sx, sy))
            else
                dst:setPixel(x, y, clear)
            end
        end
    end
    return dst
end

local function unionRect(a, b)
    if not a then return b end
    if not b then return a end
    local x1 = math.min(a.x, b.x)
    local y1 = math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

local function padRect(r, pad)
    return Geom:new{ x = r.x - pad, y = r.y - pad, w = r.w + 2 * pad, h = r.h + 2 * pad }
end

local function inRect(px, py, r)
    return r and px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h
end

-- ---------------------------------------------------------------------
-- Sticker button (one picture you can tap)
-- ---------------------------------------------------------------------

local StickerButton = InputContainer:extend{
    file = nil,
    size = 60,
    callback = nil,
}

function StickerButton:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    local pad = Size.padding.small
    local box = self.size - 2 * pad
    -- read the picture's real shape so wide or tall stickers are not squished
    local fw, fh = box, box
    local ok, img = pcall(RenderImage.renderImageFile, RenderImage, self.file, false)
    if ok and img then
        local iw, ih = img:getWidth(), img:getHeight()
        img:free()
        if iw > 0 and ih > 0 then
            if iw >= ih then fh = math.max(1, math.floor(box * ih / iw))
            else fw = math.max(1, math.floor(box * iw / ih)) end
        end
    end
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        ImageWidget:new{
            file = self.file,
            width = fw,
            height = fh,
            alpha = true,
        },
    }
end

function StickerButton:onTap()
    if self.callback then self.callback() end
    return true
end

-- ---------------------------------------------------------------------
-- The popup: text button + sticker grid
-- ---------------------------------------------------------------------

local NotePopup = InputContainer:extend{
    plugin = nil,
    anchor = nil,       -- where a new note goes
    pack_index = 1,
    page_index = 1,
}

local STICKER_COLS = 6
local STICKER_ROWS = 3

function NotePopup:init()
    self.dimen = Screen:getSize()
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldOutside = { GestureRange:new{ ges = "hold", range = self.dimen } },
        HoldPanOutside = { GestureRange:new{ ges = "hold_pan", range = self.dimen } },
        HoldReleaseOutside = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        PanOutside = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanReleaseOutside = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
    -- ask for a screen refresh of the whole popup, or it may only show up
    -- inside whatever button was tapped to open it
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function NotePopup:build()
    local p = self.plugin
    local W = Screen:getWidth()
    local width = math.floor(W * 0.88)
    local packs = p:enabledPacks()
    if self.pack_index > #packs then self.pack_index = 1 end
    local pack = packs[self.pack_index]

    local top = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {{
            { text = _("Text note"), callback = function()
                UIManager:close(self)
                p:newTextNote(self.anchor)
            end },
            { text = _("Edit notes"), callback = function()
                UIManager:close(self)
                if not p.edit_layer then p:openEditMode() end
            end },
            { text = _("Close"), callback = function() UIManager:close(self) end },
        }},
    }

    local pack_label = pack and pack.name or _("No sticker packs turned on")
    local pack_row = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {{
            { text = "◀", enabled = #packs > 1, callback = function()
                self:switchPack(self.pack_index - 1)
            end },
            { text = pack_label, enabled = false },
            { text = "▶", enabled = #packs > 1, callback = function()
                self:switchPack(self.pack_index + 1)
            end },
        }},
    }

    local grid = VerticalGroup:new{}
    local page_row
    if pack then
        local per_page = STICKER_COLS * STICKER_ROWS
        local pages = math.max(1, math.ceil(#pack.files / per_page))
        if self.page_index > pages then self.page_index = 1 end
        local first = (self.page_index - 1) * per_page + 1
        local last = math.min(#pack.files, first + per_page - 1)
        local cell = math.floor((width - 2 * Size.padding.default) / STICKER_COLS)
        local row
        for i = first, last do
            local file = pack.files[i]
            if (i - first) % STICKER_COLS == 0 then
                row = HorizontalGroup:new{}
                table.insert(grid, row)
            end
            table.insert(row, StickerButton:new{
                file = file,
                size = cell,
                callback = function()
                    UIManager:close(self)
                    p:newSticker(self.anchor, pack.name .. "/" .. file:match("([^/]+)$"))
                end,
            })
        end
        if pages > 1 then
            page_row = ButtonTable:new{
                width = width,
                show_parent = self,
                buttons = {{
                    { text = "◀", callback = function() self:switchPage(self.page_index - 1, pages) end },
                    { text = self.page_index .. " / " .. pages, enabled = false },
                    { text = "▶", callback = function() self:switchPage(self.page_index + 1, pages) end },
                }},
            }
        end
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            top,
            pack_row,
            grid,
            page_row or VerticalSpan:new{ width = Size.padding.default },
        },
    }
    self.movable = MovableContainer:new{ self.frame }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.movable,
    }
end

function NotePopup:switchPack(i)
    local packs = self.plugin:enabledPacks()
    if i < 1 then i = #packs end
    if i > #packs then i = 1 end
    UIManager:close(self)
    UIManager:show(NotePopup:new{ plugin = self.plugin, anchor = self.anchor, pack_index = i, page_index = 1 })
end

function NotePopup:switchPage(i, pages)
    if i < 1 then i = pages end
    if i > pages then i = 1 end
    UIManager:close(self)
    UIManager:show(NotePopup:new{ plugin = self.plugin, anchor = self.anchor,
        pack_index = self.pack_index, page_index = i })
end

function NotePopup:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false -- let the buttons handle it
end

-- touches on the page behind the popup do nothing; inside the frame they
-- fall through so the popup can still be dragged
function NotePopup:outside(ges)
    return not self.frame.dimen or ges.pos:notIntersectWith(self.frame.dimen)
end
function NotePopup:onHoldOutside(_, ges) return self:outside(ges) end
function NotePopup:onHoldPanOutside(_, ges) return self:outside(ges) end
function NotePopup:onHoldReleaseOutside(_, ges) return self:outside(ges) end
function NotePopup:onPanOutside(_, ges) return self:outside(ges) end
function NotePopup:onPanReleaseOutside(_, ges) return self:outside(ges) end
function NotePopup:onSwipeOutside(_, ges) return self:outside(ges) end

function NotePopup:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.frame.dimen)
end

-- ---------------------------------------------------------------------
-- Edit mode: full-screen layer that lets you drag / resize / rotate
-- ---------------------------------------------------------------------

local EditLayer = InputContainer:extend{
    plugin = nil,
}

function EditLayer:init()
    self.dimen = Screen:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = self.dimen } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = self.dimen } },
        DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
        TwoFingerTap = { GestureRange:new{ ges = "two_finger_tap", range = self.dimen } },
        TwoFingerPan = { GestureRange:new{ ges = "two_finger_pan", range = self.dimen } },
        TwoFingerSwipe = { GestureRange:new{ ges = "two_finger_swipe", range = self.dimen } },
        Spread = { GestureRange:new{ ges = "spread", range = self.dimen } },
        Pinch = { GestureRange:new{ ges = "pinch", range = self.dimen } },
    }
    self:buildToolbar()
end

function EditLayer:buildToolbar()
    local p = self.plugin
    local width = math.floor(Screen:getWidth() * 0.72)
    local function need(fn)
        return function()
            if not p.selected then
                UIManager:show(InfoMessage:new{ text = _("Tap a note first."), timeout = 2 })
                return
            end
            fn(p.selected)
        end
    end
    self.buttons = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {
            {
                { text = _("Add"), callback = function() p:openPopup(p:nextAnchor()) end },
                { text = _("Done"), callback = function() p:closeEditMode() end },
                { text = _("Delete"), callback = need(function(n) p:askDelete(n) end) },
            },
            {
                { text = _("Text"), callback = need(function(n)
                    if n.kind == "text" then p:editText(n) else p:info(_("Stickers have no text.")) end
                end) },
                { text = _("Font"), callback = need(function(n)
                    if n.kind == "text" then p:pickFont(n.font, function(f) n.font = f; p:noteChanged(n) end)
                    else p:info(_("Stickers have no font.")) end
                end) },
                { text = _("Align"), callback = need(function(n)
                    if n.kind == "text" then p:pickAlign(function(a) n.align = a; p:noteChanged(n) end)
                    else p:info(_("Stickers have no text.")) end
                end) },
                { text = _("Box"), callback = need(function(n)
                    if n.kind == "text" then n.bg = not n.bg; p:noteChanged(n)
                    else p:info(_("Stickers have no box.")) end
                end) },
            },
            {
                { text = "↺", callback = need(function(n) n.angle = (n.angle - ROTATE_STEP) % 360; p:noteChanged(n) end) },
                { text = "↻", callback = need(function(n) n.angle = (n.angle + ROTATE_STEP) % 360; p:noteChanged(n) end) },
                { text = _("Smaller"), callback = need(function(n) p:resize(n, -1) end) },
                { text = _("Bigger"), callback = need(function(n) p:resize(n, 1) end) },
                { text = _("Narrower"), callback = need(function(n) p:rewidth(n, -0.05) end) },
                { text = _("Wider"), callback = need(function(n) p:rewidth(n, 0.05) end) },
            },
            {
                { text = "←", callback = need(function(n) p:nudge(n, -NUDGE, 0) end) },
                { text = "↑", callback = need(function(n) p:nudge(n, 0, -NUDGE) end) },
                { text = "↓", callback = need(function(n) p:nudge(n, 0, NUDGE) end) },
                { text = "→", callback = need(function(n) p:nudge(n, NUDGE, 0) end) },
            },
        },
    }
    self.toolbar = MovableContainer:new{
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = 0,
            self.buttons,
        },
    }
    self[1] = BottomContainer:new{
        dimen = self.dimen,
        self.toolbar,
    }
end

-- true when the touch is on the toolbar. Handlers then return false so the
-- toolbar's own buttons and drag handling get the touch.
function EditLayer:onToolbar(ges)
    return self.toolbar.dimen and ges.pos:intersectWith(self.toolbar.dimen)
end

function EditLayer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
    local p = self.plugin
    local r = p.selected and p.rects[p.selected.id]
    if r then
        local f = padRect(r, Size.border.thick + 2)
        bb:paintBorder(f.x, f.y, f.w, f.h, Size.border.thick, Blitbuffer.COLOR_BLACK)
    end
end

function EditLayer:onTap(_, ges)
    if self:onToolbar(ges) then return false end
    if self.drag then self:endDrag() end
    local p = self.plugin
    local note = p:noteAt(ges.pos.x, ges.pos.y)
    local old = p.selected and p.rects[p.selected.id]
    p.selected = note
    local new = note and p.rects[note.id]
    local region = unionRect(old and padRect(old, 10), new and padRect(new, 10))
    if region then UIManager:setDirty(p.ui, "ui", region) end
    return true
end

function EditLayer:startDrag(sx, sy)
    local p = self.plugin
    local note = p:noteAt(sx, sy)
    if not note then
        self.drag = { none = true, sx = sx, sy = sy }
        return
    end
    local r = p.rects[note.id]
    p.selected = note
    self.drag = { note = note, ox = r.ox, oy = r.oy, last = padRect(r, 10), sx = sx, sy = sy }
end

function EditLayer:endDrag()
    local d = self.drag
    self.drag = nil
    if not d or d.none then return end
    local p = self.plugin
    local note = d.note
    if note._drag then
        note.anchor = p:makeAnchor(note._drag.x, note._drag.y)
        note._drag = nil
    end
    p:save()
    UIManager:setDirty(p.ui, "ui")
end

function EditLayer:onPan(_, ges)
    if self:onToolbar(ges) then return false end
    local p = self.plugin
    local sx = ges.pos.x - ges.relative.x
    local sy = ges.pos.y - ges.relative.y
    -- a new finger-down (different start point) means the last drag never
    -- got its release event; close it out before starting the new one
    if self.drag and (math.abs(self.drag.sx - sx) > 3 or math.abs(self.drag.sy - sy) > 3) then
        self:endDrag()
    end
    if not self.drag then self:startDrag(sx, sy) end
    if self.drag.none then return true end
    local note = self.drag.note
    local r = p.rects[note.id]
    if not r then return true end
    note._drag = { x = self.drag.ox + ges.relative.x, y = self.drag.oy + ges.relative.y }
    local new = Geom:new{ x = r.x + (note._drag.x - r.ox), y = r.y + (note._drag.y - r.oy), w = r.w, h = r.h }
    new = padRect(new, 10)
    UIManager:setDirty(p.ui, "ui", unionRect(self.drag.last, new))
    self.drag.last = new
    return true
end

function EditLayer:onPanRelease(_, ges)
    if not self.drag and self:onToolbar(ges) then return false end
    self:endDrag()
    return true
end

-- a fast flick ends as a swipe, not a pan release
function EditLayer:onSwipe(_, ges)
    if not self.drag and self:onToolbar(ges) then return false end
    local was_moving = self.drag and not self.drag.none
    self:endDrag()
    -- corner-to-corner swipe is KOReader's screenshot gesture; let it through
    local d = ges.direction
    if not was_moving and (d == "northeast" or d == "northwest" or d == "southeast" or d == "southwest") then
        self.plugin.ui:handleEvent(Event:new("Screenshot"))
    end
    return true
end

-- press-and-hold then drag moves a note too
function EditLayer:onHoldPan(arg, ges) return self:onPan(arg, ges) end
function EditLayer:onHold(_, ges)
    if self:onToolbar(ges) then return false end
    return true
end
function EditLayer:onHoldRelease(_, ges)
    if not self.drag and self:onToolbar(ges) then return false end
    self:endDrag()
    return true
end
function EditLayer:onMultiSwipe() return true end
function EditLayer:onDoubleTap() return true end
-- a two-finger tap on opposite corners is KOReader's screenshot gesture
function EditLayer:onTwoFingerTap(_, ges)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local far = math.min(W, H) * 0.5
    if not ges.span or ges.span >= far then
        self.plugin.ui:handleEvent(Event:new("Screenshot"))
    end
    return true
end
function EditLayer:onTwoFingerPan() return true end
function EditLayer:onTwoFingerSwipe() return true end
function EditLayer:onSpread() return true end
function EditLayer:onPinch() return true end

-- ---------------------------------------------------------------------
-- The plugin
-- ---------------------------------------------------------------------

local PageNotes = WidgetContainer:extend{
    name = "pagenotes",
    -- loads in the file browser too, so the gesture actions show up there
    is_doc_only = false,
}

function PageNotes:onDispatcherRegisterActions()
    Dispatcher:registerAction("pagenotes_open", {
        category = "none", event = "PageNotesOpen",
        title = _("Page notes: add note or sticker"), general = true,
    })
    Dispatcher:registerAction("pagenotes_edit", {
        category = "none", event = "PageNotesEdit",
        title = _("Page notes: edit notes"), general = true,
    })
    Dispatcher:registerAction("pagenotes_toggle", {
        category = "none", event = "PageNotesToggle",
        title = _("Page notes: show / hide notes"), general = true,
    })
end

function PageNotes:init()
    self:onDispatcherRegisterActions()
    -- everything below needs an open book
    if not self.ui or not self.ui.document or not self.view then return end

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/pagenotes.lua")
    self.user_packs_dir = DataStorage:getDataDir() .. "/pagenotes/packs"
    lfs.mkdir(DataStorage:getDataDir() .. "/pagenotes")
    lfs.mkdir(self.user_packs_dir)

    self.defaults = self.settings:readSetting("text_defaults") or {}
    self.defaults.font = self.defaults.font or "cfont"
    self.defaults.size = self.defaults.size or 20
    self.defaults.align = self.defaults.align or "left"
    self.defaults.width = self.defaults.width or 0.45
    self.defaults.bg = self.defaults.bg ~= false
    self.packs_off = self.settings:readSetting("packs_off") or {}

    self.notes = self.ui.doc_settings:readSetting("pagenotes") or {}
    self.show_notes = true
    self.rects = {}
    self.cache = {}
    self.selected = nil
    self.font_paths = {}

    self.view:registerViewModule("pagenotes", {
        paintTo = function(_, bb, x, y) self:paintNotes(bb, x, y) end,
    })

    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("13_pagenotes", function(this)
            return {
                text = _("Note / sticker"),
                callback = function()
                    local sel = this.selected_text
                    local anchor
                    if sel and sel.pos0 and not self.document.info.has_pages then
                        local box = sel.sboxes and sel.sboxes[1]
                        anchor = {
                            type = "word", pos0 = sel.pos0, pos1 = sel.pos1 or sel.pos0,
                            unit = "em", dx = 0, dy = 1,
                        }
                    elseif sel and sel.sboxes and sel.sboxes[1] then
                        local box = sel.sboxes[1]
                        anchor = self:makeAnchor(box.x, box.y + box.h)
                    end
                    this:onClose()
                    self:openPopup(anchor)
                end,
            }
        end)
    end

    self.ui.menu:registerToMainMenu(self)
end

function PageNotes:info(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

-- ---------------- saving ----------------

function PageNotes:save()
    for _, n in ipairs(self.notes) do n._drag = nil end
    self.ui.doc_settings:saveSetting("pagenotes", self.notes)
end

function PageNotes:onSaveSettings()
    if self.notes then self:save() end
end

function PageNotes:onCloseDocument()
    if self.cache then self:freeCache() end
end

function PageNotes:freeCache()
    for _, c in pairs(self.cache) do
        if c.bb then c.bb:free() end
    end
    self.cache = {}
end

-- ---------------- anchors ----------------

function PageNotes:currentPages()
    local cur = self.document:getCurrentPage()
    local ok, count = pcall(self.document.getVisiblePageCount, self.document)
    if ok and count == 2 then return cur, cur + 1 end
    return cur, cur
end

-- Try to tie screen point (px,py) to a word. x,y = where the note sits.
-- Only accepts a word that KOReader can draw a box for right now, so the
-- note lands exactly where you dropped it.
function PageNotes:wordAnchorAt(px, py, x, y)
    local W, H = Screen:getWidth(), Screen:getHeight()
    if px < 0 or py < 0 or px >= W or py >= H then return nil end
    local ok, word = pcall(self.document.getWordFromPosition, self.document, { x = px, y = py })
    if not ok or not word or not word.pos0 then return nil end
    local pos1 = word.pos1 or word.pos0
    local ok2, boxes = pcall(self.document.getScreenBoxesFromPositions, self.document, word.pos0, pos1)
    if not ok2 or not boxes or #boxes == 0 then return nil end
    local b = boxes[1]
    if not b.h or b.h < 1 then return nil end
    -- offsets are measured in line heights ("em"), so when the font grows
    -- the note moves out with it and stays next to the same spot
    return { type = "word", pos0 = word.pos0, pos1 = pos1, unit = "em",
        dx = (x - b.x) / b.h, dy = (y - b.y) / b.h }
end

-- Screen top-left (x,y) -> anchor table
function PageNotes:makeAnchor(x, y)
    if self.document.info.has_pages then
        local W, H = Screen:getWidth(), Screen:getHeight()
        return { type = "pdfpage", page = self.view.state.page, dx = x / W, dy = y / H }
    end
    local a = self:findWordAnchor(x, y)
    -- asking the book engine "what word is here?" also selects that word,
    -- which draws like a highlight. Clear it.
    if self.document.clearSelection then
        pcall(self.document.clearSelection, self.document)
    end
    return a
end

function PageNotes:findWordAnchor(x, y)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local step = 30
    -- same row first: walk from the drop point toward the far side of the screen
    local dir = (x < W / 2) and 1 or -1
    for row = 0, 2 do
        for _, py in ipairs(row == 0 and { y } or { y + row * step, y - row * step }) do
            local px = x
            while px >= 0 and px < W do
                local a = self:wordAnchorAt(px, py, x, y)
                if a then return a end
                px = px + dir * step
            end
        end
    end
    -- nothing on nearby rows: try the whole page column
    for py = 0, H - 1, step * 2 do
        local a = self:wordAnchorAt(math.floor(W / 2), py, x, y)
        if a then return a end
    end
    local cur = self.document:getCurrentPage()
    return { type = "page", xp = self.document:getXPointer(), page = cur, dx = x / W, dy = y / H }
end

-- anchor -> screen top-left of the unrotated note, or nil if not on this page
function PageNotes:noteScreenPos(note)
    if note._drag then return note._drag.x, note._drag.y end
    local a = note.anchor
    local W, H = Screen:getWidth(), Screen:getHeight()
    if a.type == "pdfpage" then
        if a.page ~= self.view.state.page then return nil end
        return a.dx * W, a.dy * H
    elseif a.type == "page" then
        local ok, page = pcall(self.document.getPageFromXPointer, self.document, a.xp)
        local p1, p2 = self:currentPages()
        local hit = ok and (page == p1 or page == p2)
        if not hit and a.page then hit = (a.page == p1 or a.page == p2) end
        if not hit then return nil end
        return a.dx * W, a.dy * H
    elseif a.type == "word" then
        if self.view.view_mode ~= "scroll" then
            local ok, page = pcall(self.document.getPageFromXPointer, self.document, a.pos0)
            if not ok then return nil end
            local p1, p2 = self:currentPages()
            if page ~= p1 and page ~= p2 then return nil end
        end
        local ok, boxes = pcall(self.document.getScreenBoxesFromPositions, self.document, a.pos0, a.pos1)
        if not ok or not boxes or #boxes == 0 then return nil end
        local b = boxes[1]
        if b.y < -H or b.y > 2 * H then return nil end
        local nx, ny
        if a.unit == "em" then
            nx, ny = b.x + a.dx * b.h, b.y + a.dy * b.h
        else -- notes saved by an older version: fraction of the screen
            nx, ny = b.x + a.dx * W, b.y + a.dy * H
        end
        -- keep the note on the page if the font change pushed it off the edge.
        -- Clamp the box as it is actually drawn (after rotation), not the
        -- unrotated one, or a sideways text box gets shoved out of the margin.
        local c = self.cache[note.id]
        if c then
            local cx, cy = nx + c.uw / 2, ny + c.uh / 2
            local dx = math.max(0, math.min(W - c.w, cx - c.w / 2))
            local dy = math.max(0, math.min(H - c.h, cy - c.h / 2))
            nx = dx + c.w / 2 - c.uw / 2
            ny = dy + c.h / 2 - c.uh / 2
        end
        return nx, ny
    end
    return nil
end

-- ---------------- drawing ----------------

function PageNotes:getFace(name, size)
    local ok, face = pcall(Font.getFace, Font, name, size)
    if ok and face then return face end
    local p = self.font_paths[name]
    if p then
        ok, face = pcall(Font.getFace, Font, p, size)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

function PageNotes:stickerPath(rel)
    local user = self.user_packs_dir .. "/" .. rel
    if lfs.attributes(user, "mode") == "file" then return user end
    local builtin = self.path .. "/packs/" .. rel
    if lfs.attributes(builtin, "mode") == "file" then return builtin end
    return nil
end

function PageNotes:noteSignature(note)
    local W = Screen:getWidth()
    if note.kind == "text" then
        return table.concat({ "t", note.text, note.font, note.size, note.align,
            note.width, tostring(note.bg), note.angle, W }, "|")
    end
    return table.concat({ "s", note.sticker, note.w, note.angle, W }, "|")
end

-- Returns {bb=RGBA buffer, w, h} for the note as it should look now.
function PageNotes:renderNote(note)
    local sig = self:noteSignature(note)
    local c = self.cache[note.id]
    if c and c.sig == sig then return c end
    if c and c.bb then c.bb:free() end

    local W = Screen:getWidth()
    local rgba
    if note.kind == "text" then
        local face = self:getFace(note.font, note.size)
        local pad = note.bg and Size.padding.default or 0
        local tb = TextBoxWidget:new{
            text = note.text,
            face = face,
            width = math.max(40, math.floor(note.width * W) - 2 * pad),
            alignment = note.align,
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_WHITE,
        }
        local s = tb:getSize()
        local tmp = Blitbuffer.new(s.w + 2 * pad, s.h + 2 * pad, Blitbuffer.TYPE_BB8)
        tmp:fill(Blitbuffer.COLOR_WHITE)
        tb:paintTo(tmp, pad, pad)
        tb:free()
        if note.bg then
            tmp:paintBorder(0, 0, tmp:getWidth(), tmp:getHeight(), Size.border.thin, Blitbuffer.COLOR_BLACK)
        end
        rgba = toRGBA(tmp, not note.bg)
        tmp:free()
    else
        local path = self:stickerPath(note.sticker)
        local pw = math.max(12, math.floor(note.w * W))
        local img = path and RenderImage:renderImageFile(path, false)
        if img then
            local ph = math.max(1, math.floor(img:getHeight() * pw / img:getWidth()))
            local scaled = RenderImage:scaleBlitBuffer(img, pw, ph)
            if scaled ~= img then img:free() end
            if scaled:getType() == Blitbuffer.TYPE_BBRGB32 then
                rgba = scaled
            else
                rgba = toRGBA(scaled, false)
                scaled:free()
            end
            cleanSticker(rgba)
        else
            -- missing picture: draw a small box so you can still find and delete it
            rgba = Blitbuffer.new(pw, pw, Blitbuffer.TYPE_BBRGB32)
            local white = Blitbuffer.ColorRGB32(255, 255, 255, 255)
            for yy = 0, pw - 1 do for xx = 0, pw - 1 do rgba:setPixel(xx, yy, white) end end
            rgba:paintBorder(0, 0, pw, pw, 2, Blitbuffer.ColorRGB32(0, 0, 0, 255))
        end
    end

    local uw, uh = rgba:getWidth(), rgba:getHeight()
    if note.angle and note.angle % 360 ~= 0 then
        local rot = rotateRGBA(rgba, note.angle)
        rgba:free()
        rgba = rot
    end

    c = { sig = sig, bb = rgba, w = rgba:getWidth(), h = rgba:getHeight(), uw = uw, uh = uh }
    self.cache[note.id] = c
    return c
end

-- Called by ReaderView after the page is drawn.
function PageNotes:paintNotes(bb, x, y)
    self.rects = {}
    if not self.show_notes then return end
    for _, note in ipairs(self.notes) do
        local nx, ny = self:noteScreenPos(note)
        if nx then
            local ok, c = pcall(self.renderNote, self, note)
            if ok and c then
                -- spin around the middle of the unrotated box
                local cx, cy = nx + c.uw / 2, ny + c.uh / 2
                local dx, dy = math.floor(cx - c.w / 2), math.floor(cy - c.h / 2)
                bb:alphablitFrom(c.bb, x + dx, y + dy, 0, 0, c.w, c.h)
                self.rects[note.id] = Geom:new{ x = x + dx, y = y + dy, w = c.w, h = c.h,
                    ox = nx, oy = ny }
            else
                logger.warn("pagenotes: could not draw note", note.id, c)
            end
        end
    end
end

function PageNotes:noteAt(px, py)
    for i = #self.notes, 1, -1 do
        local n = self.notes[i]
        local r = self.rects[n.id]
        if r then
            -- small stickers get a bigger invisible grab area
            local grow = math.max(0, MIN_GRAB - math.min(r.w, r.h)) / 2
            if inRect(px, py, padRect(r, grow)) then return n end
        end
    end
    return nil
end

function PageNotes:noteChanged(note)
    self:save()
    UIManager:setDirty(self.ui, "ui")
end

-- ---------------- making notes ----------------

function PageNotes:newId()
    return tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
end

function PageNotes:defaultAnchor()
    local W, H = Screen:getWidth(), Screen:getHeight()
    return self:makeAnchor(math.floor(W * 0.3), math.floor(H * 0.4))
end

function PageNotes:addNote(note)
    table.insert(self.notes, note)
    self:save()
    self.selected = note
    if self.edit_layer then
        UIManager:setDirty(self.ui, "ui")
    else
        self:openEditMode()
    end
end

-- where a new note goes when added from the edit toolbar: under the
-- selected note, or a default spot
function PageNotes:nextAnchor()
    local r = self.selected and self.rects[self.selected.id]
    if r then
        local H = Screen:getHeight()
        local y = r.y + r.h + 8
        if y > H - 60 then y = r.y end
        return self:makeAnchor(r.x, y)
    end
    return self:defaultAnchor()
end

function PageNotes:newTextNote(anchor)
    local d = self.defaults
    local dlg
    dlg = InputDialog:new{
        title = _("Note text"),
        input = "",
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Place"), is_enter_default = true, callback = function()
                local text = dlg:getInputText()
                UIManager:close(dlg)
                if text == "" then return end
                self:addNote{
                    id = self:newId(), kind = "text", text = text,
                    font = d.font, size = d.size, align = d.align, width = d.width, bg = d.bg,
                    angle = 0, anchor = anchor or self:defaultAnchor(),
                }
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function PageNotes:newSticker(anchor, rel)
    self:addNote{
        id = self:newId(), kind = "sticker", sticker = rel, w = 0.18,
        angle = 0, anchor = anchor or self:defaultAnchor(),
    }
end

function PageNotes:editText(note)
    local dlg
    dlg = InputDialog:new{
        title = _("Note text"),
        input = note.text,
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local text = dlg:getInputText()
                UIManager:close(dlg)
                if text == "" then return end
                note.text = text
                self:noteChanged(note)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function PageNotes:resize(note, dir)
    if note.kind == "text" then
        note.size = math.min(80, math.max(6, note.size + 2 * dir))
    else
        note.w = math.min(1, math.max(0.04, note.w * (dir > 0 and 1.15 or 0.87)))
    end
    self:noteChanged(note)
end

-- move a note a few pixels with the arrow buttons
function PageNotes:nudge(note, dx, dy)
    local r = self.rects[note.id]
    if not r then return end
    note.anchor = self:makeAnchor(r.ox + dx, r.oy + dy)
    self:save()
    UIManager:setDirty(self.ui, "ui", padRect(r, math.abs(dx) + math.abs(dy) + 12))
end

function PageNotes:rewidth(note, delta)
    if note.kind ~= "text" then
        self:info(_("Use Smaller / Bigger for stickers."))
        return
    end
    note.width = math.min(1, math.max(0.15, note.width + delta))
    self:noteChanged(note)
end

function PageNotes:askDelete(note)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this note?"),
        ok_text = _("Delete"),
        ok_callback = function()
            for i, n in ipairs(self.notes) do
                if n == note then table.remove(self.notes, i) break end
            end
            if self.cache[note.id] then
                self.cache[note.id].bb:free()
                self.cache[note.id] = nil
            end
            self.selected = nil
            self:save()
            UIManager:setDirty(self.ui, "ui")
        end,
    })
end

-- ---------------- pickers ----------------

function PageNotes:pickFont(current, cb)
    local items = { { text = _("Default (KOReader font)"), callback = function() cb("cfont") end } }
    for _, path in ipairs(FontList:getFontList()) do
        local name = path:match("([^/]+)$")
        self.font_paths[name] = path
        table.insert(items, {
            text = (name:gsub("%.%w+$", "")),
            callback = function() cb(name) end,
        })
    end
    local menu
    menu = Menu:new{
        title = _("Font"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            item.callback()
        end,
    }
    UIManager:show(menu)
end

function PageNotes:pickAlign(cb)
    local dlg
    dlg = ButtonDialog:new{
        buttons = {{
            { text = _("Left"), callback = function() UIManager:close(dlg) cb("left") end },
            { text = _("Middle"), callback = function() UIManager:close(dlg) cb("center") end },
            { text = _("Right"), callback = function() UIManager:close(dlg) cb("right") end },
        }},
    }
    UIManager:show(dlg)
end

function PageNotes:pickSize(current, cb)
    UIManager:show(SpinWidget:new{
        title_text = _("Text size"),
        value = current, value_min = 6, value_max = 80, default_value = 20,
        callback = function(spin) cb(spin.value) end,
    })
end

-- ---------------- packs ----------------

function PageNotes:scanPacks()
    local packs = {}
    local function scan(root, builtin)
        if lfs.attributes(root, "mode") ~= "directory" then return end
        for name in lfs.dir(root) do
            if name:sub(1, 1) ~= "." then
                local dir = root .. "/" .. name
                if lfs.attributes(dir, "mode") == "directory" then
                    local files = {}
                    for f in lfs.dir(dir) do
                        local ext = f:lower():match("%.(%w+)$")
                        if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "svg" then
                            table.insert(files, dir .. "/" .. f)
                        end
                    end
                    table.sort(files)
                    if #files > 0 then
                        table.insert(packs, { name = name, dir = dir, files = files, builtin = builtin })
                    end
                end
            end
        end
    end
    scan(self.path .. "/packs", true)
    scan(self.user_packs_dir, false)
    table.sort(packs, function(a, b) return a.name < b.name end)
    return packs
end

function PageNotes:enabledPacks()
    local out = {}
    for _, p in ipairs(self:scanPacks()) do
        if not self.packs_off[p.name] then table.insert(out, p) end
    end
    return out
end

-- ---------------- open / close ----------------

function PageNotes:openPopup(anchor)
    UIManager:show(NotePopup:new{ plugin = self, anchor = anchor })
end

function PageNotes:openEditMode()
    if self.edit_layer then return end
    self.show_notes = true
    self.edit_layer = EditLayer:new{ plugin = self }
    UIManager:show(self.edit_layer)
    UIManager:setDirty(self.ui, "ui")
end

function PageNotes:closeEditMode()
    if not self.edit_layer then return end
    UIManager:close(self.edit_layer)
    self.edit_layer = nil
    self.selected = nil
    self:save()
    UIManager:setDirty(self.ui, "ui")
end

function PageNotes:onPageNotesOpen()
    if not self.notes then return true end
    self:openPopup(self:defaultAnchor())
    return true
end

function PageNotes:onPageNotesEdit()
    if not self.notes then return true end
    self:openEditMode()
    return true
end

function PageNotes:onPageNotesToggle()
    if not self.notes then return true end
    self.show_notes = not self.show_notes
    UIManager:setDirty(self.ui, "ui")
    return true
end

-- ---------------- main menu ----------------

function PageNotes:addToMainMenu(menu_items)
    menu_items.pagenotes = {
        text = _("Page notes"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

function PageNotes:menuItems()
    local d = self.defaults
    local function saveDefaults()
        self.settings:saveSetting("text_defaults", d)
        self.settings:flush()
    end
    local packs = {}
    for _, p in ipairs(self:scanPacks()) do
        table.insert(packs, {
            text = p.name .. " (" .. #p.files .. ")",
            checked_func = function() return not self.packs_off[p.name] end,
            callback = function()
                if self.packs_off[p.name] then self.packs_off[p.name] = nil else self.packs_off[p.name] = true end
                self.settings:saveSetting("packs_off", self.packs_off)
                self.settings:flush()
            end,
        })
    end
    if #packs == 0 then
        packs = { { text = _("No packs found"), enabled = false } }
    end
    return {
        { text = _("Add note or sticker"), callback = function() self:onPageNotesOpen() end },
        { text = _("Edit notes"), callback = function() self:onPageNotesEdit() end },
        {
            text = _("Show notes"),
            checked_func = function() return self.show_notes end,
            callback = function() self:onPageNotesToggle() end,
            separator = true,
        },
        {
            text = _("Sticker packs"),
            sub_item_table = packs,
        },
        {
            text = _("New text notes"),
            sub_item_table = {
                { text_func = function() return _("Font: ") .. (d.font == "cfont" and _("Default") or d.font) end,
                  callback = function() self:pickFont(d.font, function(f) d.font = f saveDefaults() end) end },
                { text_func = function() return _("Size: ") .. d.size end,
                  callback = function() self:pickSize(d.size, function(s) d.size = s saveDefaults() end) end },
                { text_func = function() return _("Align: ") .. d.align end,
                  callback = function() self:pickAlign(function(a) d.align = a saveDefaults() end) end },
                { text = _("White box behind text"),
                  checked_func = function() return d.bg end,
                  callback = function() d.bg = not d.bg saveDefaults() end },
            },
            separator = true,
        },
        {
            text = _("Delete all notes in this book"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete every note and sticker in this book?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self.notes = {}
                        self:freeCache()
                        self:save()
                        UIManager:setDirty(self.ui, "ui")
                    end,
                })
            end,
        },
    }
end

return PageNotes
