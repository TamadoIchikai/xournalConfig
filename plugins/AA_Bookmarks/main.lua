utf8_to_html = require("utf8_to_html")

DEFAULT_EXPORT_PATH = "/tmp/temp"

-- Helper function to get mouse position
function get_mouse_position()
  local hasLgi, lgi = pcall(require, "lgi")
  if not hasLgi then return nil, nil end
  local pointer = lgi.Gdk.Display.get_default():get_default_seat():get_pointer()
  if not pointer then return nil, nil end
  local _, x, y = pointer:get_position()
  return x, y
end

-- Centralized Bookmark Parsing
function parse_bookmark(txt)
  local prefix, content = txt:match("^(%*)%s*(.*)")
  if not prefix then
    prefix, content = txt:match("^(%-+>)%s*(.*)")
  end
  return prefix, content
end

-- Set current layer in a version-tolerant way.
-- Xournal++ 1.3.4 accepts: app.setCurrentLayer(layerNr, change_visibility)
function set_current_layer_compat(layer)
  if not layer then return false end

  local ok = pcall(app.setCurrentLayer, layer, false)
  if ok then return true end

  ok = pcall(app.setCurrentLayer, layer)
  return ok
end

-- Xournal++ 1.3.4 only supports app.getTexts("selection") and app.getTexts("layer").
-- Newer builds support app.getTexts("page") and app.getTexts("all").
-- This helper uses the native "all" API when available, otherwise it scans
-- every page/layer and adds the missing page/layer fields manually.
function get_all_texts_compat()
  local okAll, allTexts = pcall(app.getTexts, "all")
  if okAll and type(allTexts) == "table" then
    return allTexts
  end

  local structure = app.getDocumentStructure()
  if not structure or not structure.pages then return {} end

  local oldPage = structure.currentPage
  local oldLayer = 1
  if oldPage and structure.pages[oldPage] and structure.pages[oldPage].currentLayer then
    oldLayer = structure.pages[oldPage].currentLayer
  end

  local collected = {}

  for page = 1, #structure.pages do
    app.setCurrentPage(page)

    local pageInfo = structure.pages[page]
    local numLayers = 1
    if pageInfo and pageInfo.layers then
      numLayers = #pageInfo.layers
      if numLayers < 1 then numLayers = 1 end
    end

    for layer = 1, numLayers do
      if set_current_layer_compat(layer) then
        local okLayer, layerTexts = pcall(app.getTexts, "layer")
        if okLayer and type(layerTexts) == "table" then
          for _, t in ipairs(layerTexts) do
            local item = {}
            for k, v in pairs(t) do item[k] = v end
            item.page = page
            item.layer = layer
            table.insert(collected, item)
          end
        end
      end
    end
  end

  if oldPage then app.setCurrentPage(oldPage) end
  if oldLayer then set_current_layer_compat(oldLayer) end

  return collected
end


-- Escape a filename/path for POSIX shell commands.
function shell_quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

-- Decode the XML entities used inside .xopp text elements.
function xml_unescape(str)
  if not str then return "" end

  local function utf8_char(code)
    code = tonumber(code)
    if not code then return "" end

    if utf8 and utf8.char then
      local ok, ch = pcall(utf8.char, code)
      if ok and ch then return ch end
    end

    -- Fallback for plain ASCII if utf8.char is unavailable.
    if code >= 0 and code <= 127 then return string.char(code) end
    return ""
  end

  str = str:gsub("&#x(%x+);", function(hex) return utf8_char(tonumber(hex, 16)) end)
  str = str:gsub("&#(%d+);", function(dec) return utf8_char(tonumber(dec, 10)) end)
  str = str:gsub("&quot;", "\"")
  str = str:gsub("&apos;", "'")
  str = str:gsub("&lt;", "<")
  str = str:gsub("&gt;", ">")
  str = str:gsub("&amp;", "&")
  return str
end

function xml_attr(attrs, name)
  if not attrs then return nil end
  local value = attrs:match(name .. '="([^"]*)"')
  if value then return xml_unescape(value) end
  value = attrs:match(name .. "='([^']*)'")
  if value then return xml_unescape(value) end
  return nil
end

-- Read the saved .xopp file without changing the visible page.
-- .xopp files are gzip-compressed XML, so this uses gzip -cd on Linux.
function read_xopp_xml_from_disk()
  local structure = app.getDocumentStructure()
  local filename = structure and structure.xoppFilename

  if not filename or filename == "" then
    return nil, "Document has not been saved yet."
  end

  local cmd = "gzip -cd -- " .. shell_quote(filename) .. " 2>/dev/null"
  local pipe = io.popen(cmd, "r")
  if not pipe then return nil, "Unable to run gzip." end

  local xml = pipe:read("*a")
  pipe:close()

  if not xml or xml == "" then
    return nil, "Unable to read saved .xopp file."
  end

  return xml, nil
end

-- Best-effort normal save before opening the no-reload bookmark manager.
-- The manager reads the saved .xopp XML, so this keeps the on-disk file fresh
-- without scanning all pages/layers through the visible UI.
function save_document_for_bookmark_manager()
  local structure = app.getDocumentStructure()
  local filename = structure and structure.xoppFilename

  -- If the document has never been saved, Xournal++ needs a real Save As
  -- interaction first. Do not open the manager with stale/current-layer data.
  if not filename or filename == "" then
    pcall(app.activateAction, "save-as")
    pcall(app.activateAction, "document-save-as")
    pcall(app.uiAction, { action = "ACTION_SAVE_AS" })

    return false, "Document has not been saved yet. Save it as a .xopp file, then open Bookmark Manager again."
  end

  -- Try the known action names across Xournal++ versions/builds.
  -- app.activateAction is the modern API; app.uiAction is kept as a fallback.
  local attempted = false

  local actionNames = {
    "save",
    "document-save",
    "file-save"
  }

  for _, actionName in ipairs(actionNames) do
    local ok = pcall(app.activateAction, actionName)
    attempted = attempted or ok
    if ok then break end
  end

  if not attempted then
    local ok = pcall(app.uiAction, { action = "ACTION_SAVE" })
    attempted = attempted or ok
  end

  if not attempted then
    return false, "Unable to trigger Xournal++ save action."
  end

  return true, nil
end

-- Fast, no-UI-jump text reader for the bookmark manager.
-- This intentionally does not call app.setCurrentPage() unless the native
-- app.getTexts("all") API exists, so opening the manager will not reload pages.
function get_all_texts_no_reload()
  local okAll, allTexts = pcall(app.getTexts, "all")
  if okAll and type(allTexts) == "table" then
    return allTexts, "api"
  end

  local xml = read_xopp_xml_from_disk()
  if not xml then
    -- Last-resort no-jump fallback: only current layer, because scanning all
    -- layers/pages would cause the visual reload/jump the user wanted to avoid.
    local structure = app.getDocumentStructure()
    local currentPage = structure and structure.currentPage or 1
    local currentLayer = 1
    if structure and structure.pages and structure.pages[currentPage] then
      currentLayer = structure.pages[currentPage].currentLayer or 1
    end

    local okLayer, layerTexts = pcall(app.getTexts, "layer")
    if not okLayer or type(layerTexts) ~= "table" then return {}, "current-layer" end

    local currentTexts = {}
    for _, t in ipairs(layerTexts) do
      local item = {}
      for k, v in pairs(t) do item[k] = v end
      item.page = item.page or currentPage
      item.layer = item.layer or currentLayer
      table.insert(currentTexts, item)
    end

    return currentTexts, "current-layer"
  end

  local texts = {}
  local pageNr = 0

  for pageAttrs, pageBody in xml:gmatch("<page([^>]*)>(.-)</page>") do
    pageNr = pageNr + 1
    local layerNr = 0

    for layerAttrs, layerBody in pageBody:gmatch("<layer([^>]*)>(.-)</layer>") do
      layerNr = layerNr + 1

      for textAttrs, encodedText in layerBody:gmatch("<text%s+([^>]*)>(.-)</text>") do
        table.insert(texts, {
          text = xml_unescape(encodedText),
          page = pageNr,
          layer = layerNr,
          x = tonumber(xml_attr(textAttrs, "x")) or 0,
          y = tonumber(xml_attr(textAttrs, "y")) or 0,
          color = xml_attr(textAttrs, "color"),
          font = {
            name = xml_attr(textAttrs, "font") or "Sans Regular",
            size = tonumber(xml_attr(textAttrs, "size")) or 12.0
          },
          ref = nil
        })
      end
    end
  end

  return texts, "xopp"
end

function text_coord_close(a, b)
  if a == nil or b == nil then return true end
  return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 0.75
end

-- Resolve a bookmark row from the no-reload .xopp list into a live element ref.
-- This is only used when the user intentionally activates/edits/deletes a row.
function resolve_bookmark_element(bookmark)
  if not bookmark then return nil end
  if bookmark.ref then return bookmark.ref, bookmark end

  app.setCurrentPage(bookmark.page)
  set_current_layer_compat(bookmark.layer or 1)

  local okTexts, layerTexts = pcall(app.getTexts, "layer")
  if not okTexts or type(layerTexts) ~= "table" then return nil end

  local fallback = nil
  for _, t in ipairs(layerTexts) do
    if (t.text or "") == (bookmark.name or bookmark.text or "") then
      fallback = fallback or t

      if text_coord_close(t.x, bookmark.x) and text_coord_close(t.y, bookmark.y) then
        bookmark.ref = t.ref
        bookmark.x = t.x
        bookmark.y = t.y
        bookmark.color = t.color
        bookmark.font = t.font
        return t.ref, t
      end
    end
  end

  if fallback then
    bookmark.ref = fallback.ref
    bookmark.x = fallback.x
    bookmark.y = fallback.y
    bookmark.color = fallback.color
    bookmark.font = fallback.font
    return fallback.ref, fallback
  end

  return nil
end

-- Centralized Bookmark Styling
function get_bookmark_style(text, defaultFontName)
  -- Strip out any existing variants including "Black"
  local baseFontFamily = defaultFontName:gsub(" Regular$", ""):gsub(" Bold$", ""):gsub(" Italic$", ""):gsub(" Black$", "")
  local fontName = baseFontFamily
  local fontSize = 25.0

  if text:match("^%*") then
    if baseFontFamily == "Segoe UI" then
      fontName = baseFontFamily .. " Black"
    else
      fontName = baseFontFamily .. " Bold"
    end
    fontSize = 25.0
  elseif text:match("^%-+>") then
    local depth = string.len(text:match("^(%-+)>"))
    if depth == 1 then
      if baseFontFamily == "Segoe UI" then
        fontName = baseFontFamily .. " Bold"
      else
        fontName = baseFontFamily .. " Regular"
      end
      fontSize = 20.0
    else
      fontName = baseFontFamily .. " Regular"
      fontSize = math.max(15.0, 20.0 - ((depth - 1) * 5.0))
    end
  end
  return fontName, fontSize
end

-- Register Toolbar
function initUi()
  app.registerUi({menu="Previous Bookmark", toolbarId="CUSTOM_PREVIOUS_BOOKMARK", callback="search_bookmark", mode=-1, iconName="go-previous"})
  app.registerUi({menu="New Bookmark", toolbarId="CUSTOM_NEW_BOOKMARK", callback="dialog_new_bookmark", iconName="bookmark-new-symbolic", ["accelerator"]="B"})
  app.registerUi({menu="New Bookmark (No dialog)", toolbarId="CUSTOM_NEW_BOOKMARK_NO_DIALOG", callback="new_bookmark", iconName="bookmark-new-symbolic"})
  app.registerUi({menu="Next Bookmark", toolbarId="CUSTOM_NEXT_BOOKMARK", callback="search_bookmark", mode=1, iconName="go-next"})
  app.registerUi({menu="View Bookmarks", toolbarId="CUSTOM_VIEW_BOOKMARKS", callback = "view_bookmarks", iconName="user-bookmarks-symbolic", ["accelerator"]="<Shift>B"})
  app.registerUi({menu="Export to PDF with Bookmarks", toolbarId="CUSTOM_EXPORT_WITH_BOOKMARKS", callback="export", iconName="xopp-document-export-pdf"})

  local sep = package.config:sub(1,1)
  sourcePath = debug.getinfo(1).source:match("@?(.*" .. sep .. ")")
  if sep == "\\" then DEFAULT_EXPORT_PATH = "%TEMP%\\temp" end
end

function new_bookmark(name)
  if not name or name == "" then return end

  local fontColor = 0x000000
  local fontName = "Sans Regular"
  
  local textToolInfo = app.getToolInfo("text")
  if textToolInfo then
    fontName = (textToolInfo.font and textToolInfo.font.name) or fontName
    fontColor = textToolInfo.color or fontColor
  end

  local newFontName, newFontSize = get_bookmark_style(name, fontName)

  -- Add the text and capture the reference so we can select it
  local refs = app.addTexts({
    texts = {
      { text = name, x = 20, y = 20, color = fontColor, font = { name = newFontName, size = newFontSize } }
    }
  })

  -- Automatically select the newly created bookmark
  if refs and #refs > 0 then
    local currentPage = app.getDocumentStructure().currentPage
    app.clearSelection()
    app.addToSelection(refs)
    app.scrollToPage(currentPage)
  end
end

function search_bookmark(mode)
  local allTexts = get_all_texts_compat()
  if not allTexts then return end

  local bookmarkPages = {}
  for _, t in ipairs(allTexts) do
    if parse_bookmark(t.text or "") and t.page then
      bookmarkPages[t.page] = true
    end
  end

  local structure = app.getDocumentStructure()
  local numPages = #structure.pages
  local page = structure.currentPage

  for _ = 1, numPages do
    page = page + mode
    if page > numPages then page = 1 end
    if page < 1 then page = numPages end
    
    if bookmarkPages[page] then
      app.setCurrentPage(page)
      app.scrollToPage(page)
      return
    end
  end

  app.openDialog("No bookmark found.", {"Ok"}, "")
end

function dialog_new_bookmark()
  local hasLgi, lgi = pcall(require, "lgi")
  if not hasLgi then return new_bookmark() end

  local Gtk = lgi.require("Gtk", "3.0")
  local builder = Gtk.Builder()
  assert(builder:add_from_file(sourcePath .. "dlgNew.glade"))
  
  local ui = builder.objects
  local dialog = ui.dlgNew
  dialog:set_title("Xournalpp - New bookmark")
  ui.btnNewOk:set_sensitive(false)

  function ui.entryName:on_changed()
    ui.btnNewOk:set_sensitive(parse_bookmark(self:get_text()) ~= nil)
  end

  local function ok()
    local name = ui.entryName:get_text()
    if parse_bookmark(name) then
      new_bookmark(name)
      dialog:destroy()
    end
  end

  ui.btnNewOk.on_clicked = ok
  ui.entryName.on_activate = ok
  function ui.btnNewCancel:on_clicked() dialog:destroy() end

  local mouse_x, mouse_y = get_mouse_position()
  dialog:show_all()
  if mouse_x and mouse_y then
    dialog:move(mouse_x - dialog:get_allocated_width() / 2, mouse_y - dialog:get_allocated_height() / 2)
  end
end

function delete_bookmark(page, layer, elementRef)
  if not elementRef then return end
  app.setCurrentPage(page)
  set_current_layer_compat(layer or 1)
  app.clearSelection()
  app.addToSelection({elementRef})
  app.activateAction("delete")
  app.clearSelection()
end

function view_bookmarks()
  local saved, saveErr = save_document_for_bookmark_manager()
  if not saved then
    return app.openDialog("Save required", {"OK"}, saveErr or "Save the document, then open Bookmark Manager again.", true)
  end

  local hasLgi, lgi = pcall(require, "lgi")
  if not hasLgi then
    return app.openDialog("Lua lgi-module is required to view bookmarks.", {"OK"}, "")
  end

  local Gtk = lgi.require("Gtk", "3.0")
  local builder = Gtk.Builder()
  assert(builder:add_from_file(sourcePath .. "dlgBookmarks.glade"))

  local ui, dialog = builder.objects, builder.objects.dlgBookmarks
  dialog:set_title("Xournalpp - Bookmarks Manager")

  -- Keep the ListStore simple and store a Lua-side bookmark index.
  -- The actual live element ref is resolved lazily only when needed.
  local column = { PAGE = 1, LAYER = 2, PREFIX = 3, DISPLAY_NAME = 4, NAME = 5, IDX = 6 }
  local store = Gtk.ListStore.new {
    [column.PAGE] = lgi.GObject.Type.UINT,
    [column.LAYER] = lgi.GObject.Type.UINT,
    [column.PREFIX] = lgi.GObject.Type.STRING,
    [column.DISPLAY_NAME] = lgi.GObject.Type.STRING,
    [column.NAME] = lgi.GObject.Type.STRING,
    [column.IDX] = lgi.GObject.Type.UINT
  }

  local bookmarks = {}

  local function get_bookmark_from_iter(model, iter)
    if not model or not iter then return nil end
    local idx = model[iter][column.IDX]
    if not idx then return nil end
    return bookmarks[idx]
  end

  local function update_row_from_bookmark(model, iter, b)
    if not model or not iter or not b then return end
    local prefix, content = parse_bookmark(b.name or b.text or "")
    b.prefix = prefix or b.prefix or ""
    b.displayName = content or b.displayName or ""
    model[iter][column.PAGE] = b.page or 1
    model[iter][column.LAYER] = b.layer or 1
    model[iter][column.PREFIX] = b.prefix
    model[iter][column.DISPLAY_NAME] = b.displayName
    model[iter][column.NAME] = b.name or b.text or ""
  end

  local function updateTable()
    store:clear()
    bookmarks = {}

    local allTexts = get_all_texts_no_reload()
    local currentPage = app.getDocumentStructure().currentPage
    local closest_exact_idx, closest_below_idx, closest_above_idx

    for _, t in ipairs(allTexts or {}) do
      local prefix, content = parse_bookmark(t.text or "")
      if prefix and t.page then
        table.insert(bookmarks, {
          page = t.page,
          layer = t.layer or 1,
          prefix = prefix,
          displayName = content,
          name = t.text,
          text = t.text,
          ref = t.ref,
          x = t.x or 0,
          y = t.y or 0,
          color = t.color,
          font = t.font
        })
      end
    end

    table.sort(bookmarks, function(a, b)
      if a.page ~= b.page then return a.page < b.page end
      if (a.layer or 1) ~= (b.layer or 1) then return (a.layer or 1) < (b.layer or 1) end
      return (a.y or 0) < (b.y or 0)
    end)

    for i, b in ipairs(bookmarks) do
      store:append({b.page, b.layer or 1, b.prefix, b.displayName, b.name, i})

      -- Track nearest page index.
      if b.page == currentPage then
        if not closest_exact_idx then closest_exact_idx = i end
      elseif b.page < currentPage then
        closest_below_idx = i
      elseif b.page > currentPage then
        if not closest_above_idx then closest_above_idx = i end
      end
    end

    local best_idx = nil
    if closest_exact_idx then
      best_idx = closest_exact_idx
    else
      local dist_below = closest_below_idx and (currentPage - bookmarks[closest_below_idx].page) or math.huge
      local dist_above = closest_above_idx and (bookmarks[closest_above_idx].page - currentPage) or math.huge
      if dist_below <= dist_above and closest_below_idx then
        best_idx = closest_below_idx
      elseif closest_above_idx then
        best_idx = closest_above_idx
      end
    end

    return best_idx
  end

  local initial_best_idx = updateTable()

  local nameRenderer = Gtk.CellRendererText { editable = true }
  function nameRenderer:on_edited(path_str, new_text)
    local success, iter = store:get_iter(Gtk.TreePath.new_from_string(path_str))
    iter = type(success) == "userdata" and success or iter
    if not iter then return end

    local model = store
    local b = get_bookmark_from_iter(model, iter)
    if not b then return end

    local final_text = new_text:match("^%s*(.-)$") or ""
    local typed_prefix, typed_content = parse_bookmark(final_text)

    if not typed_prefix then
      local old_prefix = parse_bookmark(b.name or "")
      if old_prefix then final_text = old_prefix .. " " .. final_text end
    else
      final_text = typed_prefix .. " " .. typed_content
    end

    if not parse_bookmark(final_text) then
      return app.openDialog("Invalid Bookmark", {"OK"}, "Must start with '*' or '->'.", true)
    end

    local ref, liveEl = resolve_bookmark_element(b)
    if not ref then
      return app.openDialog("Bookmark not found in current document.", {"OK"}, "Save/reopen the document or refresh the bookmark list.", true)
    end

    app.clearSelection()
    app.addToSelection({ref})

    local selTexts = app.getTexts("selection")
    if selTexts and #selTexts > 0 then
      local oldEl = selTexts[1]
      app.activateAction("delete")
      app.clearSelection()

      local fontName = "Sans Regular"
      if oldEl.font and oldEl.font.name then fontName = oldEl.font.name end

      local newFontName, newFontSize = get_bookmark_style(final_text, fontName)
      local refs = app.addTexts({
        texts = {
          {
            text = final_text,
            x = oldEl.x,
            y = oldEl.y,
            color = oldEl.color,
            font = { name = newFontName, size = newFontSize }
          }
        }
      })

      b.name = final_text
      b.text = final_text
      b.x = oldEl.x
      b.y = oldEl.y
      b.color = oldEl.color
      b.font = { name = newFontName, size = newFontSize }
      b.ref = refs and refs[1] or nil

      update_row_from_bookmark(model, iter, b)
    else
      app.clearSelection()
    end
  end

  -- Restored Declarative Syntax to prevent 0-indexing layout bug
  local treeView = Gtk.TreeView {
    model = store,
    Gtk.TreeViewColumn { 
      title = "Page", sizing = "FIXED", fixed_width = 50, 
      { Gtk.CellRendererText {}, {text = column.PAGE} } 
    },
    Gtk.TreeViewColumn { 
      title = "", sizing = "FIXED", fixed_width = 40, 
      { Gtk.CellRendererText {}, {text = column.PREFIX} } 
    },
    Gtk.TreeViewColumn {
      title = "Name",
      expand = true,
      {
        nameRenderer,
        {text = column.DISPLAY_NAME},
      }
    }
  }

  -- Manual Drag-to-Scroll implementation with Inertia Physics for Stylus users
  local drag_active = false
  local drag_start_y = 0
  local scroll_start_val = 0
  local last_y = 0
  local velocity = 0
  local scroll_tick = nil

  local function stop_inertia()
    if scroll_tick then
      lgi.GLib.source_remove(scroll_tick)
      scroll_tick = nil
    end
  end

  function treeView:on_button_press_event(event)
    if event.button == 1 then
      drag_active = true
      drag_start_y = event.y_root
      last_y = event.y_root
      scroll_start_val = ui.scrolledWindow:get_vadjustment():get_value()
      velocity = 0
      stop_inertia()
    end
    return false -- allow event to propagate to rows for selection/editing
  end

  function treeView:on_button_release_event(event)
    if event.button == 1 then 
      drag_active = false 
      if math.abs(velocity) > 1.5 then
        scroll_tick = lgi.GLib.timeout_add(lgi.GLib.PRIORITY_DEFAULT, 16, function()
          if drag_active then return false end

          local vadj = ui.scrolledWindow:get_vadjustment()
          local new_val = vadj:get_value() - velocity

          local lower_limit = vadj:get_lower()
          local upper_limit = vadj:get_upper() - vadj:get_page_size()

          if new_val <= lower_limit then 
            new_val = lower_limit
            velocity = 0 
          elseif new_val >= upper_limit then 
            new_val = upper_limit
            velocity = 0 
          end

          vadj:set_value(new_val)
          velocity = velocity * 0.90 -- Friction/Decay multiplier

          if math.abs(velocity) < 0.5 then
            scroll_tick = nil
            return false
          end
          return true
        end)
      end
    end
    return false
  end

  function treeView:on_motion_notify_event(event)
    if drag_active then
      velocity = event.y_root - last_y
      last_y = event.y_root

      local dy = drag_start_y - event.y_root
      local vadj = ui.scrolledWindow:get_vadjustment()
      vadj:set_value(scroll_start_val + dy)

      -- If we moved a noticeable amount, consume the event so we don't accidentally drag-select multiple rows
      if math.abs(dy) > 5 then return true end
    end
    return false
  end

  ui.scrolledWindow:add(treeView)

  function treeView:on_row_activated(path)
    local model, iter = self:get_model(), self:get_model():get_iter(path)
    if iter then
      local b = get_bookmark_from_iter(model, iter)
      if not b then return end

      app.setCurrentPage(b.page)
      set_current_layer_compat(b.layer or 1)
      app.scrollToPage(b.page)

      local ref = resolve_bookmark_element(b)
      if ref then
        app.clearSelection()
        app.addToSelection({ref})
      end

      dialog:destroy()
    end
  end

  function ui.btnNew:on_clicked()
    dialog_new_bookmark()
  end

  function ui.btnDelete:on_clicked()
    local model, iter = treeView:get_selection():get_selected()
    if not iter then return end

    local b = get_bookmark_from_iter(model, iter)
    if not b then return end

    local ref = resolve_bookmark_element(b)
    if not ref then
      return app.openDialog("Bookmark not found in current document.", {"OK"}, "Save/reopen the document or refresh the bookmark list.", true)
    end

    app.clearSelection()
    app.addToSelection({ref})
    app.activateAction("delete")
    app.clearSelection()

    -- Remove from the visible manager immediately without re-scanning all pages.
    pcall(function() store:remove(iter) end)
  end

  function dialog:on_destroy() stop_inertia() end

  function ui.btnDone:on_clicked() dialog:destroy() end

  local mx, my = get_mouse_position()
  dialog:show_all()
  if mx and my then dialog:move(mx - dialog:get_allocated_width() / 2, my - dialog:get_allocated_height() / 2) end

  -- Select and scroll to nearest bookmark upon opening the dialog
  if initial_best_idx then
    local path = lgi.Gtk.TreePath.new_from_string(tostring(initial_best_idx - 1))
    treeView:get_selection():select_path(path)
    treeView:scroll_to_cell(path, nil, true, 0.5, 0.0)
  end
end

function export()
  if not os.execute("pdftk") then return app.openDialog("pdftk is missing.", {"OK"}, "") end

  local structure = app.getDocumentStructure()
  local defaultName = (structure.xoppFilename and structure.xoppFilename:match("(.+)%..+$") or DEFAULT_EXPORT_PATH) .. "_export.pdf"
  local path = app.saveAs(defaultName)
  if not path then return end

  local sep = package.config:sub(1,1)
  local tempData = os.tmpname()
  if sep == "\\" then tempData = tempData:sub(2) end
  local tempPdf = tempData .. "_1337__.pdf"

  app.export({outputFile = tempPdf})
  os.execute("pdftk \"" .. tempPdf .. "\" dump_data output \"" .. tempData .. "\"")

  local bookmarks = {}
  local allTexts = get_all_texts_compat()
  
  for _, t in ipairs(allTexts) do
    if parse_bookmark(t.text or "") and t.page then
      table.insert(bookmarks, { page = t.page, name = utf8_to_html(t.text), y = t.y or 0 })
    end
  end
  
  table.sort(bookmarks, function(a, b) return a.page == b.page and a.y < b.y or a.page < b.page end)
  
  local file = io.open(tempData,"a+")
  for _, b in ipairs(bookmarks) do
    file:write("BookmarkBegin\nBookmarkTitle: " .. b.name .. "\nBookmarkLevel: 1\nBookmarkPageNumber: " .. b.page .. "\n")
  end
  file:close()

  os.execute("pdftk \"" .. tempPdf .. "\" update_info \"" .. tempData .. "\" output \"" .. path .."\"")
  os.remove(tempData)
  os.remove(tempPdf)
end