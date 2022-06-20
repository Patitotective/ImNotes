import std/[strformat, strutils, os]

import imstyle
import niprefs
import nimgl/[opengl, glfw]
import nimgl/imgui, nimgl/imgui/[impl_opengl, impl_glfw]

import src/[prefsmodal, utils, icons]
when defined(release):
  from resourcesdata import resources

const maxTextBuffer = 500
const maxTitleBuffer = 64
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

proc newNote(page: var Page, title = "") = 
  let title = if title.len > 0: title else: &"Note #{page.len+1}"
  page.add Note(title: newString(maxTitleBuffer, title), text: newString(maxTextBuffer))

proc drawNote(app: var App, index: int, width, height: float32, anyActiveTitle: var bool, dragging: var bool): string = 
  # Returns the action clicked in the note's context menu
  let style = igGetStyle()
  let note = app.books[app.currentBook][app.currentPage][index]

  igPushStyleVar(ChildRounding, 10)
  igPushStyleVar(WindowPadding, igVec2(7, 7))
  igPushStyleColor(ChildBg, igGetColorU32(FrameBg))

  let headerHeight = igGetFrameHeight() + (style.windowPadding.y * 2)

  if igBeginChild(cstring "##noteChild", size = igVec2(width, height), flags = AlwaysUseWindowPadding):
    igPushStyleVar(ItemSpacing, igVec2(0, 0))

    igSetNextItemWidth(width - (style.windowPadding.x + igCalcFrameSize(FA_EllipsisH).x + style.windowPadding.x))

    if app.activeTitle != index:
      igPushStyleColor(Text, igGetColorU32(TextDisabled))

    igInputTextWithHint(cstring "##noteTitle", cstring "Title", cstring note.title, 64); igSameLine()

    if app.activeTitle != index:
      igPopStyleColor()

    if igIsItemActive():
      anyActiveTitle = true
      app.activeTitle = index
    igCenterCursorX(igCalcFrameSize(FA_EllipsisH).x + style.windowPadding.x, 1)

    if igButton(FA_EllipsisH):
      igOpenPopup("context")

    if igBeginDragDropSource(SourceNoPreviewTooltip):
      igSetDragDropPayload("NOTE", nil, 0) # No payload data since it's already being stored at app.dragSource
      app.dragSource = index
      dragging = true
      igEndDragDropSource()

    igPushStyleVar(ImGuiStyleVar.FramePadding, igVec2(7, 7))
    igInputTextMultiline(cstring "##noteText", cstring note.text, maxTextBuffer, size = igVec2(width - (style.windowPadding.x * 2), height - headerHeight))

    igPopStyleVar(2)

  igPopStyleColor()
  igPopStyleVar(2)
  
  if igBeginPopup("context"):
    if igMenuItem(cstring "Delete " & FA_TrashO):
      app.boks[app.currentBook][app.currentPage].delete(index)
      if page.len == 0 and app.books[app.currentBook].pages.len > 1:
        app.books[app.currentBook].pages.delete(app.currentPage)
        app.currentPage = app.books[app.currentBook].pages.high

    igEndPopup()

  igEndChild()

  if app.dragSource != index and igBeginDragDropTarget():
    if (let payload = igAcceptDragDropPayload("NOTE"); not payload.isNil):
      (page[app.dragSource], page[index]) = (page[index], page[app.dragSource])
    igEndDragDropTarget()

proc drawPage(app: var App, page: var Page) = 
  let style = igGetStyle()
  let avail = igGetContentRegionAvail()

  var widthNum, heightNum: int
  if page.len in 2..3 and (page.len + 1) mod 2 == 0:
    widthNum = (page.len + 1) div 2
    heightNum = widthNum
  else:
    widthNum = clamp(page.len + 1, 2, 3)
    heightNum = clamp((page.len + 2) - widthNum, 1, 2)

  echo widthNum, ":", heightNum

  igPushStyleVar(ItemSpacing, igVec2(15, 15))

  let noteWidth = (igGetContentRegionAvail().x - (style.itemSpacing.x * float32(widthNum - 1))) / float32 widthNum
  let noteHeight = (igGetContentRegionAvail().y - (style.itemSpacing.y * float32(heightNum - 1))) / float32 heightNum
  # let noteHeight =
    # if e == 0 and (page.len + 1) == 5: 
      # (noteHeight * 2) + style.itemSpacing.y
    # else: noteHeight

  var anyActiveTitle = false
  var dragging = false

  for e in 0..<(widthNum * heightNum):
    igPushID(cstring &"{app.currentPage}:{e}")
    if e < page.len:
      # echo "mod ", e, ": ", (e-1) mod heightNum
  
      # if e > 0 and (e - 1) mod heightNum == 0: # First note in a column
        # igBeginGroup()

      app.drawNote(e, noteWidth, noteHeight, anyActiveTitle, dragging)

      # if e == 0 and (page.len + 1) == 5:
        # igSameLine()
      # elif e > 0 and (e - 1) mod heightNum == (heightNum - 1): # Last note in a column
        # igEndGroup()

    elif e == page.len:
      app.bigFont.igPushFont()
      igPushStyleVar(ImGuiStyleVar.FramePadding, igVec2(7, 5))
      
      if igButton(FA_Plus):
        page.newNote()
      
      igPopStyleVar()
      igPopFont()

      # if e > 0 and (e - 1) mod heightNum == (heightNum - 1): # Last note in a column
        # igEndGroup()

    else:
      igDummy(igVec2(noteWidth, noteHeight))

    if (e + 1) mod widthNum > 0:
      igSameLine()

    igPopID()

  if not anyActiveTitle:
    app.activeTitle = -1

  if not dragging:
    app.dragSource = -1 

  igPopStyleVar()

proc drawBook(app: var App, book: var Book) = 
  app.drawPage(book.pages[app.currentPage])

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

  # See https://github.com/ocornut/imgui/issues/331#issuecomment-751372071
  if openPrefs:
    igOpenPopup("Preferences")
  if openAbout:
    igOpenPopup(cstring "About " & app.config["name"].getString())

  # These modals will only get drawn when igOpenPopup(name) are called, respectly
  app.drawAboutModal()
  app.drawPrefsModal()

proc drawStatusBar(app: var App) = 
  let viewport = igGetMainViewport()

  app.bigFont.igPushFont()
  if igBeginViewportSideBar("##statusBar", viewport, ImGuiDir.Down, igGetFrameHeight(), makeFlags(NoScrollbar, MenuBar)):
    if igBeginMenuBar():
      for e, page in app.books[app.currentBook].pages:
        var disabled = false
        if app.currentPage == e:
          disabled = true
          igBeginDisabled()

        if igButton(cstring $(e + 1)):
          app.currentPage = e

        if disabled:
          igEndDisabled()

      if igButton(FA_Plus):
        app.books[app.currentBook].pages.add default(Page)
        app.books[app.currentBook].pages[^1].newNote()
        app.currentPage = app.books[app.currentBook].pages.high

      igEndMenuBar()
  igEnd()
  igPopFont()

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

    app.drawBook(app.books[app.currentBook])

  igPopStyleVar()
  igEnd()

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
          pages: toTTables [
            {notes: toTTables [{title: "Note #1", text: "Type here..."}]}, 
          ], 
        }, 
      ], 
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
    for page in book["pages"]:
      var p: Page
      for note in page["notes"]:
        p.add Note(title: newString(maxTitleBuffer, note["title"].getString), text: newString(maxTextBuffer, note["title"].getString()))

      b.pages.add p

    result.books.add b

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
    var b = toTTable {title: book.title.cleanString(), pages: toTTables []}
    for page in book.pages:
      var p = toTTable {notes: toTTables []}
      for note in page:
        p["notes"].add toTTable {title: note.title.cleanString(), text: note.text.cleanString()}

      b["pages"].add p

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

  app.bigFont = io.fonts.igAddFontFromMemoryTTF(app.config["fontPath"].getData(), app.config["fontSize"].getFloat()+4)

  io.fonts.igAddFontFromMemoryTTF(app.config["iconFontPath"].getData(), app.config["fontSize"].getFloat()+4, config.addr, ranges[0].addr)

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
