import std/[strformat, strutils, os]

import imstyle
import niprefs
import nimgl/[opengl, glfw]
import nimgl/imgui, nimgl/imgui/[impl_opengl, impl_glfw]

import src/[prefsmodal, utils, icons]
when defined(release):
  from resourcesdata import resources

const maxTextBuffer = 1000
const maxTitleBuffer = 64
const menuPadding = igVec2(6, 10)
const configPath = "config.toml"

proc getData(path: string): string = 
  when defined(release):
    resources[path]
  else:
    readFile(path)

proc getData(node: TomlValueRef): string = 
  assert node.kind == TomlKind.String
  node.getString().getData()

proc getCacheDir(app: App): string = 
  getCacheDir(app.config["name"].getString())

template curBook(app: App): Book = 
  app.books[app.currentBook]

template curPage(app: App): seq[Note] = 
  let startNote = int app.currentPage * app.prefs["maxNotes"].getInt()
  let endNote = int startNote + app.prefs["maxNotes"].getInt()
  app.curBook.notes[startNote..(if endNote > app.curBook.notes.high: app.curBook.notes.high else: endNote)]

proc newNote(app: var App) = 
  app.curBook.notes.add Note(title: newString(maxTitleBuffer, &"Note #{app.curBook.notes.len+1}"), text: newString(maxTextBuffer))

proc drawNote(app: var App, index: int, width, height: float32, dragging: var bool) = 
  igPushStyleVar(ChildRounding, 10)
  igPushStyleVar(ItemSpacing, igVec2(6, 0))
  igPushStyleVar(WindowPadding, igVec2(10, 10))
  igPushStyleColor(ChildBg, igGetColorU32(FrameBg))

  let style = igGetStyle()
  let note = app.curBook.notes[index]

  let headerHeight = igGetFrameHeight() + (style.windowPadding.y * 2) + style.itemSpacing.y + 1 # Separator is 1 pixel tall
  let ellipsisBtnSize = 
    if app.selecting: igVec2(igGetFrameHeight(), igGetFrameHeight())
    else: igCalcFrameSize(FA_EllipsisH)

  var active = false
  var selected = index in app.selected

  if igBeginChild(cstring "##noteChild", size = igVec2(width, height), flags = AlwaysUseWindowPadding):

    igSetNextItemWidth(width - style.windowPadding.x - style.itemSpacing.x - ellipsisBtnSize.x - style.windowPadding.x)

    igPushStyleVar(ImGuiStyleVar.FramePadding, igVec2(0, 0))
    igInputTextWithHint(cstring "##noteTitle", cstring "Title", cstring note.title, 64); igSameLine()
    igPopStyleVar()

    if igIsItemActive():
      active = true

    let (titleMin, titleMax) = (igGetItemRectMin(), igGetItemRectMax())

    igCenterCursorX(style.itemSpacing.x + ellipsisBtnSize.x + style.windowPadding.x, 1)

    if app.selecting:
      igPushStyleColor(FrameBg, igGetColorU32(PopupBg))
      igCheckbox("##select", selected.addr)
      igPopStyleColor()

      if selected and index notin app.selected:
        app.selected.add index
      elif not selected and index in app.selected:
        app.selected.delete app.selected.find(index)
        if app.selected.len == 0:
          app.selecting = false
  
    else:
      if igButton(FA_EllipsisH):
        igOpenPopup("context")

      if igBeginDragDropSource():
        igSetDragDropPayload("NOTE", nil, 0) # No payload data since it's already being stored at app.dragSource
        app.dragSource = index
        dragging = true
        igText("Swap Note")
        igEndDragDropSource()

    igItemSize(igVec2(0, 1))
    igGetWindowDrawList().addLine(igVec2(titleMin.x, titleMax.y), titleMax, igGetColorU32(ImGuiCol.Separator), 1)

    igPushStyleVar(ImGuiStyleVar.FramePadding, igVec2(0, 0))
    igInputTextMultiline(cstring "##noteText", cstring note.text, maxTextBuffer, size = igVec2(width - (style.windowPadding.x * 2), height - headerHeight))
    igPopStyleVar()

    if igIsItemActive():
      active = true

  igPopStyleVar(2); igPopStyleColor()
  
  igPushStyleVar(WindowPadding, menuPadding)
  igPushStyleVar(ItemSpacing, igVec2(6, 6))

  if igBeginPopup("context"):
    if igMenuItem("Move to trash"):
      app.trash.notes.add app.curBook.notes[index]
      app.curBook.notes.delete(index)

    if igMenuItem("Select"):
      app.selecting = true
      app.selected.add index

    igEndPopup()

  igPopStyleVar(2)

  igEndChild()

  if (not app.selecting and active) or (app.selecting and selected):
    let window = igGetCurrentWindow()
    var display_rect = igRect(igGetItemRectMin(), igGetItemRectMax())
    display_rect.addr.clipWith(window.clipRect)
    
    let thickness = 2f
    let distance = 3f + thickness * 0.5f

    display_rect.expand(distance)

    let fully_visible = display_rect in window.clipRect

    if not fully_visible:
      window.drawList.pushClipRect(display_rect.min, display_rect.max)

    window.drawList.addRect(
      display_rect.min + thickness * 0.5f,  
      display_rect.max - thickness * 0.5f, 
      igGetColorU32(ImGuiCol.NavHighlight), 
      style.childRounding, 
      0.ImDrawFlags, 
      thickness
    )

    if not fully_visible:
      window.drawList.popClipRect()

  if app.dragSource != index and igBeginDragDropTarget():
    if (let payload = igAcceptDragDropPayload("NOTE"); not payload.isNil):
      (app.curBook.notes[app.dragSource], app.curBook.notes[index]) = (app.curBook.notes[index], app.curBook.notes[app.dragSource])
    igEndDragDropTarget()

  igPopStyleVar() # Child rounding

proc drawPage(app: var App) = 
  let style = igGetStyle()

  igPushStyleVar(ItemSpacing, style.windowPadding)

  let avail = igGetContentRegionAvail()

  let widthNum = clamp(app.curPage.len + 1, 2, (int app.prefs["maxNotes"].getInt() + 1) div 2)
  let heightNum = clamp((app.curPage.len + 2) - widthNum, 1, 2)

  let noteWidth = (igGetContentRegionAvail().x - (style.itemSpacing.x * float32(widthNum - 1))) / float32 widthNum
  let noteHeight = (igGetContentRegionAvail().y - (style.itemSpacing.y * float32(heightNum - 1))) / float32 heightNum
  # let noteHeight =
    # if e == 0 and (app.curPage.len + 1) == 5: 
      # (noteHeight * 2) + style.itemSpacing.y
    # else: noteHeight

  var dragging = false

  for e in 0..<(widthNum * heightNum):
    igPushID(cstring &"{app.currentPage}/{e}")
    if e < app.curPage.len:
      # echo "mod ", e, ": ", (e-1) mod heightNum
  
      # if e > 0 and (e - 1) mod heightNum == 0: # First note in a column
        # igBeginGroup()

      app.drawNote(int(app.currentPage * app.prefs["maxNotes"].getInt()) + e, noteWidth, noteHeight, dragging)

      # if e == 0 and (app.curPage.len + 1) == 5:
        # igSameLine()
      # elif e > 0 and (e - 1) mod heightNum == (heightNum - 1): # Last note in a column
        # igEndGroup()

    elif e == app.curPage.len:
      app.bigFont.igPushFont()
      igPushStyleVar(ImGuiStyleVar.FramePadding, igVec2(7, 5))
      
      if igButton(FA_Plus):
        app.newNote()
      
      igPopStyleVar()
      igPopFont()

      # if e > 0 and (e - 1) mod heightNum == (heightNum - 1): # Last note in a column
        # igEndGroup()

    else:
      igDummy(igVec2(noteWidth, noteHeight))

    if (e + 1) mod widthNum > 0:
      igSameLine()

    igPopID()

  igPopStyleVar()

  if not dragging:
    app.dragSource = -1 

proc drawBookList(app: var App) = 
  discard

proc drawAboutModal(app: App) = 
  var center: ImVec2
  getCenterNonUDT(center.addr, igGetMainViewport())
  igSetNextWindowPos(center, Always, igVec2(0.5f, 0.5f))
  let unusedOpen = true # Passing this parameter creates a close button
  if igBeginPopupModal(cstring "About " & app.config["name"].getString(), unusedOpen.unsafeAddr, flags = makeFlags(ImGuiWindowFlags.NoResize)):
    # Display icon image
    var texture: GLuint
    var image = app.config["iconPath"].getData().readImageFromMemory()

    image.loadTextureFromData(texture)

    igImage(cast[ptr ImTextureID](texture), igVec2(64, 64)) # Or igVec2(image.width.float32, image.height.float32)
    if igIsItemHovered():
      igSetTooltip(cstring app.config["website"].getString() & " " & FA_ExternalLink)
      
      if igIsMouseClicked(ImGuiMouseButton.Left):
        app.config["website"].getString().openURL()

    igSameLine()
    
    igPushTextWrapPos(250)
    igTextWrapped(app.config["comment"].getString().cstring)
    igPopTextWrapPos()

    igSpacing()

    # To make it not clickable
    igPushItemFlag(ImGuiItemFlags.Disabled, true)
    igSelectable("Credits", true, makeFlags(ImGuiSelectableFlags.DontClosePopups))
    igPopItemFlag()

    if igBeginChild("##credits", igVec2(0, 75)):
      for author in app.config["authors"]:
        let (name, url) = block: 
          let (name,  url) = author.getString().removeInside('<', '>')
          (name.strip(),  url.strip())

        if igSelectable(cstring name) and url.len > 0:
            url.openURL()
        if igIsItemHovered() and url.len > 0:
          igSetTooltip(cstring url & " " & FA_ExternalLink)
      
      igEndChild()

    igSpacing()

    igText(app.config["version"].getString().cstring)

    igEndPopup()

proc drawMainMenuBar(app: var App) =
  var openAbout, openPrefs = false

  igPushStyleVar(WindowPadding, menuPadding)
  if igBeginMainMenuBar():
    if igBeginMenu("File"):
      igMenuItem("Preferences " & FA_Cog, "Ctrl+P", openPrefs.addr)
      if igMenuItem("Quit " & FA_Times, "Ctrl+Q"):
        app.win.setWindowShouldClose(true)
      igEndMenu()

    if igBeginMenu("Edit"):
      if igMenuItem("Hello"):
        echo "Hello"

      igEndMenu()

    if igBeginMenu("About"):
      if igMenuItem("Website " & FA_ExternalLink):
        app.config["website"].getString().openURL()

      igMenuItem(cstring "About " & app.config["name"].getString(), shortcut = nil, p_selected = openAbout.addr)

      igEndMenu() 

    igEndMainMenuBar()

  igPopStyleVar()

  # See https://github.com/ocornut/imgui/issues/331#issuecomment-751372071
  if openPrefs:
    igOpenPopup("Preferences")
  if openAbout:
    igOpenPopup(cstring "About " & app.config["name"].getString())

  # These modals will only get drawn when igOpenPopup(name) are called, respectly
  app.drawAboutModal()
  app.drawPrefsModal()

proc drawStatusBar(app: var App) = 
  igPushStyleColor(ImGuiCol.WindowBg, igGetColorU32(MenuBarBg))
  igPushStyleColor(ImGuiCol.ChildBg, igGetColorU32(MenuBarBg))
  igPushStyleVar(WindowPadding, igVec2(5, 5))

  app.bigFont.igPushFont()

  let viewport = igGetMainViewport()
  let style = igGetStyle()

  if igBeginViewportSideBar("##statusBar", viewport, ImGuiDir.Down, igGetFrameHeight() + (style.windowPadding.y * 2), makeFlags(NoScrollbar, AlwaysUseWindowPadding)):
    if app.currentBook >= 0:
      if igButton(FA_ArrowLeft):
        app.currentBook = -1

      igSameLine()

    # Draw page number buttons
    let pagesNum = int(app.curBook.notes.len div app.prefs["maxNotes"].getInt()) + 1
    var leftDisabled, rightDisabled = false
    # Calculate the spacing between page number buttons 
    var pagesBtnsWidth = (style.itemSpacing.x * float32(pagesNum - 1))

    # Subtract one spacing so the spacing of the carets and the spacing of the clipped number button (because since 5 pages scrollbar is used) don't add
    if pagesNum >= 4:
      pagesBtnsWidth -= style.itemSpacing.x

    # Do not display more than 5 page number buttons at once
    for e in 0..<clamp(pagesNum, 0, 5):
      pagesBtnsWidth += igCalcFrameSize($(e + 1)).x

    let width = igCalcFrameSize(FA_CaretLeft).x + style.itemSpacing.x + pagesBtnsWidth +  style.itemSpacing.x + igCalcFrameSize(FA_CaretRight).x

    igCenterCursorX(width)

    if app.currentPage == 0:
      leftDisabled = true
      igBeginDisabled()

    if igButton(FA_CaretLeft):
      app.prevPage = app.currentPage
      dec app.currentPage

    if leftDisabled:
      igEndDisabled()

    igSameLine()

    if igBeginChild("##pageNums", size = igVec2(pagesBtnsWidth, 0), false):
      for e in 0..<pagesNum:
        var disabled = false
        if app.currentPage == e:
          disabled = true
          igBeginDisabled()

        if igButton(cstring $(e + 1)):
          app.currentPage = e

        if disabled:
          if app.prevPage != app.currentPage:
            app.prevPage =  app.currentPage
            igSetScrollHereX()
          igEndDisabled()

        if e < pagesNum:
          igSameLine()
    
    igEndChild(); igSameLine()

    # TODO Scroll on drag
    # if igIsMouseDragging(ImGuiMouseButton.Left):
      # echo igGetMouseDragDelta(ImGuiMouseButton.Left).x
      # igGetMouseDragDelta(ImGuiMouseButton.Left).x.igSetScrollX()

    if igIsItemHovered():
      igGetIO().keyShift = true
      igGetIO().keyMods = ImGuiKeyModFlags.Shift

    if (app.currentPage + 1) == pagesNum:
      rightDisabled = true
      igBeginDisabled()

    if igButton(FA_CaretRight):
      app.prevPage = app.currentPage
      inc app.currentPage

    if rightDisabled:
      igEndDisabled()

    if app.currentBook >= 0:
      igPushStyleVar(ImGuiStyleVar.FramePadding, igVec2(12, style.framePadding.y))
      igSameLine(); igSetCursorPosX(igGetCurrentWindow().size.x - igCalcFrameSize(FA_EllipsisV).x - style.windowPadding.x)

      if igButton(FA_EllipsisV):
        igOpenPopup("pageMenu")

      igPopStyleVar()

    igPushStyleVar(WindowPadding, menuPadding)
    app.font.igPushFont()
    if igBeginPopup("pageMenu"):
      if app.selecting:
        if igMenuItem("Move to trash"):
          app.selecting = false
          for index in app.selected:
            app.trash.notes.add app.curBook.notes[index]
            app.curBook.notes.delete(index)

          app.selected.reset()

        if igMenuItem("Pop selection"):
          app.selecting = false
          app.selected.reset()
      else:
        if igMenuItem("Select page"):
          app.selecting = true
          for e in 0..app.curPage.high:
            app.selected.add int(app.currentPage * app.prefs["maxNotes"].getInt()) + e

      igEndPopup()
    igPopFont(); igPopStyleVar()

  igEnd(); igPopFont(); igPopStyleVar(); igPopStyleColor(2)

proc drawMain(app: var App) = # Draw the main window
  let viewport = igGetMainViewport()

  app.drawMainMenuBar()
  app.drawStatusBar()

  # Work area is the entire viewport minus main menu bar, task bars, etc.
  igSetNextWindowPos(viewport.workPos)
  igSetNextWindowSize(viewport.workSize)

  igPushStyleVar(WindowRounding, 0)
  if igBegin(cstring app.config["name"].getString(), flags = makeFlags(ImGuiWindowFlags.NoResize, NoDecoration, NoMove, NoBringToFrontOnFocus)):
    igText(FA_Info & " Application average %.3f ms/frame (%.1f FPS)", 1000f / igGetIO().framerate, igGetIO().framerate)

    if app.currentBook >= 0:
      app.drawBookList()
    else:
      app.drawPage()

  igPopStyleVar()
  igEnd()

  # GLFW clipboard -> ImGui clipboard
  if not app.win.getClipboardString().isNil and $app.win.getClipboardString() != app.lastClipboard:
    igsetClipboardText(app.win.getClipboardString())
    app.lastClipboard = $app.win.getClipboardString()

  # ImGui clipboard -> GLFW clipboard
  if not igGetClipboardText().isNil and $igGetClipboardText() != app.lastClipboard:
    app.win.setClipboardString(igGetClipboardText())
    app.lastClipboard = $igGetClipboardText()

proc render(app: var App) = # Called in the main loop
  # Poll and handle events (inputs, window resize, etc.)
  glfwPollEvents() # Use glfwWaitEvents() to only draw on events (more efficient)

  # Start Dear ImGui Frame
  igOpenGL3NewFrame()
  igGlfwNewFrame()
  igNewFrame()

  # Draw application
  app.drawMain()

  # Render
  igRender()

  var displayW, displayH: int32
  let bgColor = igColorConvertU32ToFloat4(uint32 WindowBg)

  app.win.getFramebufferSize(displayW.addr, displayH.addr)
  glViewport(0, 0, displayW, displayH)
  glClearColor(bgColor.x, bgColor.y, bgColor.z, bgColor.w)
  glClear(GL_COLOR_BUFFER_BIT)

  igOpenGL3RenderDrawData(igGetDrawData())  

  app.win.makeContextCurrent()
  app.win.swapBuffers()

proc initWindow(app: var App) = 
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)
  glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
  glfwWindowHint(GLFWResizable, GLFW_TRUE)

  app.win = glfwCreateWindow(
    int32 app.prefs{"win", "width"}.getInt(), 
    int32 app.prefs{"win", "height"}.getInt(), 
    cstring app.config["name"].getString(), 
    icon = false # Do not use default icon
  )

  if app.win == nil:
    quit(-1)

  # Set the window icon
  var icon = initGLFWImage(app.config["iconPath"].getData().readImageFromMemory())
  app.win.setWindowIcon(1, icon.addr)

  app.win.setWindowSizeLimits(app.config["minSize"][0].getInt().int32, app.config["minSize"][1].getInt().int32, GLFW_DONT_CARE, GLFW_DONT_CARE) # minWidth, minHeight, maxWidth, maxHeight

  # If negative pos, center the window in the first monitor
  if app.prefs{"win", "x"}.getInt() < 0 or app.prefs{"win", "y"}.getInt() < 0:
    var monitorX, monitorY, count: int32
    let monitors = glfwGetMonitors(count.addr)
    let videoMode = monitors[0].getVideoMode()

    monitors[0].getMonitorPos(monitorX.addr, monitorY.addr)
    app.win.setWindowPos(
      monitorX + int32((videoMode.width - int app.prefs{"win", "width"}.getInt()) / 2), 
      monitorY + int32((videoMode.height - int app.prefs{"win", "height"}.getInt()) / 2)
    )
  else:
    app.win.setWindowPos(app.prefs{"win", "x"}.getInt().int32, app.prefs{"win", "y"}.getInt().int32)

proc initPrefs(app: var App) = 
  app.prefs = initPrefs(
    path = (app.getCacheDir() / app.config["name"].getString()).changeFileExt("toml"), 
    default = toToml {
      win: {
        x: -1, # Negative numbers center the window
        y: -1,
        width: 600,
        height: 650
      }, 
      currentBook: 0, 
      currentPage: 0, 
      books: toTTables [
        {
          title: "Notes", 
          notes: toTTables [{title: "Note #1", text: "Type here..."}], 
        }, 
      ], 
      trash: {title: "Trash", notes: newTTables()}, 
    }
  )

proc initApp(config: TomlValueRef): App = 
  result = App(config: config, cache: newTTable())
  result.initPrefs()
  result.initSettings(result.config["settings"])

  result.currentBook = int result.prefs["currentBook"].getInt()
  result.currentPage = int result.prefs["currentPage"].getInt()

  for book in result.prefs["books"]:
    var b = Book(title: newString(maxTitleBuffer, book["title"].getString()))
    if "notes" in book:
      for note in book["notes"]:
        b.notes.add Note(title: newString(maxTitleBuffer, note["title"].getString()), text: newString(maxTextBuffer, note["text"].getString()))

    result.books.add b

  result.trash = Book(title: "Trash")
  if "notes" in result.prefs["trash"]:
    for note in result.prefs["trash"]:
      result.trash.notes.add Note(title: newString(maxTitleBuffer, note["title"].getString()), text: newString(maxTextBuffer, note["text"].getString()))

proc terminate(app: var App) = 
  var x, y, width, height: int32

  app.win.getWindowPos(x.addr, y.addr)
  app.win.getWindowSize(width.addr, height.addr)
  
  app.prefs{"win", "x"} = x
  app.prefs{"win", "y"} = y
  app.prefs{"win", "width"} = width
  app.prefs{"win", "height"} = height

  # Save notes
  app.prefs["currentBook"] = app.currentBook
  app.prefs["currentPage"] = app.currentPage

  app.prefs["books"] = newTTables()
  for book in app.books:
    var b = toTTable {title: book.title.cleanString(), notes: toTTables []}
    for note in book.notes:
      b["notes"].add toTTable {title: note.title.cleanString(), text: note.text.cleanString(strip = false)}

    app.prefs["books"].add b

  app.prefs.save()

proc main() =
  var app = initApp(Toml.decode(configPath.getData(), TomlValueRef))

  # Setup Window
  doAssert glfwInit()
  app.initWindow()
  
  app.win.makeContextCurrent()
  glfwSwapInterval(1) # Enable vsync

  doAssert glInit()

  # Setup Dear ImGui context
  igCreateContext()
  let io = igGetIO()
  io.iniFilename = nil # Disable .ini config file

  # Setup Dear ImGui style using ImStyle
  setStyleFromToml(Toml.decode(app.config["stylePath"].getData(), TomlValueRef))

  # Setup Platform/Renderer backends
  doAssert igGlfwInitForOpenGL(app.win, true)
  doAssert igOpenGL3Init()

  # Load fonts
  app.font = io.fonts.igAddFontFromMemoryTTF(app.config["fontPath"].getData(), app.config["fontSize"].getFloat())

  # Merge ForkAwesome icon font
  var config = utils.newImFontConfig(mergeMode = true)
  var ranges = [FA_Min.uint16,  FA_Max.uint16]

  io.fonts.igAddFontFromMemoryTTF(app.config["iconFontPath"].getData(), app.config["fontSize"].getFloat(), config.addr, ranges[0].addr)

  app.bigFont = io.fonts.igAddFontFromMemoryTTF(app.config["fontPath"].getData(), app.config["fontSize"].getFloat()+6)

  io.fonts.igAddFontFromMemoryTTF(app.config["iconFontPath"].getData(), app.config["fontSize"].getFloat()+6, config.addr, ranges[0].addr)

  # Main loop
  while not app.win.windowShouldClose:
    app.render()

  # Cleanup
  igOpenGL3Shutdown()
  igGlfwShutdown()
  
  igDestroyContext()
  
  app.terminate()
  app.win.destroyWindow()
  glfwTerminate()

when isMainModule:
  main()
