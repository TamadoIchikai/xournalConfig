local selectionIndex=1
local lastPressTime = 0
local doublePressInterval =30 -- time interval in ms
local zoomIn_LastPressedTime = 0
local zoomOut_LastPressedTime = 0
local savedZoom = 1.0

-- Register all Toolbar actions and intialize all UI stuff
function initUi()
  app.registerUi({["menu"] = "Turn on eraser tool", ["callback"] = "eraser", ["accelerator"] = "e"});
  app.registerUi({["menu"] = "Turn on pen tool", ["callback"] = "pen", ["accelerator"] = "p"});
  app.registerUi({["menu"] = "Turn on select tool", ["callback"] = "select_Tool", ["accelerator"] = "s"});
  app.registerUi({["menu"] = "Floating toolbar", ["callback"] = "floating", ["accelerator"] = "t"});
  app.registerUi({["menu"] = "Zoom in", ["callback"] = "zoomIn", ["accelerator"] = "<Ctrl><Alt>equal"});
  app.registerUi({["menu"] = "Zoom out", ["callback"] = "zoomOut", ["accelerator"] = "<Ctrl><Alt>minus"});
  app.registerUi({["menu"] = "Half window down", ["callback"] = "halfWindowDown", ["accelerator"] = "<Ctrl>J"});
  app.registerUi({["menu"] = "Half window up",   ["callback"] = "halfWindowUp",   ["accelerator"] = "<Ctrl>K"});
-- ADD MORE CODE, IF NEEDED
end

function halfWindowDown()
  local pos = app.getScrollPos()       -- {x,y,width,height}
  local dy = pos.height / 2
  app.scrollToPos(0, dy, true)         -- relative scroll: down
end

function halfWindowUp()
  local pos = app.getScrollPos()
  local dy = pos.height / 2
  app.scrollToPos(0, -dy, true)        -- relative scroll: up
end
function eraser()
  app.uiAction({["action"]="ACTION_TOOL_ERASER"})
end

function pen()
  app.uiAction({["action"]="ACTION_TOOL_PEN"})
end

function select_Tool()
  local currentTime = os.time() * 1000
  if currentTime - lastPressTime <= doublePressInterval then
    app.uiAction({["action"]="ACTION_TOOL_SELECT_REGION"})
  else 
    app.uiAction({["action"]="ACTION_TOOL_SELECT_RECT"})
  end
    lastPressTime = currentTime
end

function floating()
 app.uiAction({["action"]="ACTION_TOOL_FLOATING_TOOLBOX"})
end

function zoomIn()
  local currentTime = os.time() * 1000
  if currentTime - zoomIn_LastPressedTime <= doublePressInterval then
    app.setZoom(2.0)
  else 
    app.uiAction({["action"]="ACTION_ZOOM_IN"})
  end
    zoomIn_LastPressedTime  = currentTime
end

function zoomOut()
  local currentTime = os.time() * 1000
  if currentTime - zoomOut_LastPressedTime <= doublePressInterval then
    app.setZoom(1.2)
  else 
    app.uiAction({["action"]="ACTION_ZOOM_OUT"})
  end
    zoomOut_LastPressedTime  = currentTime
end