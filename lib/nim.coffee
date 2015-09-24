{BufferedProcess, Point} = require 'atom'
SubAtom = require 'sub-atom'
Config = require './config'
Linter = require './linter'
AutoCompleter = require './auto-completer'
ProjectManager = require './project-manager'
Executor = require './executor'
{CommandTypes, AutoCompleteOptions} = require './constants'
{hasExt, arrayEqual, separateSpaces, debounce} = require './util'
cp = require "child_process"
shell = require 'shell'
#process.exit(0);

checkForExecutable = (executablePath, cb) ->
  if executablePath != ''
    try
      process = new BufferedProcess
        command: executablePath
        args: ['--version']
        exit: (code) =>
          cb(code == 0)
          
      process.onWillThrowError ({error,handle}) =>
        handle()
        cb false
    catch e
      cb false
  else
    cb false

fixExecutableFilename = (executablePath) ->
  if executablePath.indexOf('~') != -1
    executablePath.replace('~', process.env.HOME)
  else
    executablePath

navigateToFile = (file, line, col, sourceEditor) ->
  # This function uses Nim coordinates
  atomLine = line - 1
  atom.workspace.open(file)
    .done (ed) ->
      # This belongs to the current project, even if it may be in a different place
      if not ed.nimProject?
        ed.nimProject = sourceEditor.nimProject
      pos = new Point(atomLine, col)
      ed.scrollToBufferPosition(pos, center: true)
      ed.setCursorBufferPosition(pos)
  
module.exports =
  config: Config

  updateProjectsOnEditors: ->
    # Try to match up old and new projects
    for editor in atom.workspace.getTextEditors()
      if editor.nimProject?
        editor.nimProject = 
          if editor.nimProject.folderPath?
            @projectManager.getProjectForPath editor.nimProject.folderPath
          else
            @projectManager.getProjectForPath editor.getPath()
    null

  updateProjectManager: ->
    @projectManager.update(atom.project.rootDirectories.map((x) -> x.path), @options)
    @updateProjectsOnEditors()

  checkForExes: (cb) ->
    oldNimExists = @options.nimExists
    oldNimSuggestExists = @options.nimSuggestExists
    checkedNim = false
    checkedNimSuggest = false

    done = =>
      if not @options.nimExists
        atom.notifications.addError "Could not find nim executable, please check nim package settings"
      else if oldNimExists == false
        atom.notifications.addSuccess "Found nim executable"

      if not @options.nimSuggestExists and @options.nimSuggestEnabled
        atom.notifications.addError "Could not find nimsuggest executable, please check nim package settings"

      if @options.nimSuggestExists and oldNimSuggestExists == false
        atom.notifications.addSuccess "Found nimsuggest executable"

      cb()

    checkForExecutable @options.nimExe, (found) =>
      @options.nimExists = found
      checkedNim = true
      if checkedNimSuggest
          done()

    checkForExecutable @options.nimSuggestExe, (found) =>
      @options.nimSuggestExists = found
      checkedNimSuggest = true
      if checkedNim
          done()

  activate: (state) ->
    #shell.openItem 'd:\\nimtest\\run.bat'
    #cp.exec 'cmd /k /s d:\\nimtest\\run.bat',
    #  cwd: 'd:\\nimtest'

    @options =
      rootFilenames: separateSpaces(atom.config.get 'nim.projectFilenames')
      nimSuggestExe: fixExecutableFilename(atom.config.get('nim.nimsuggestExecutablePath') or 'nimsuggest')
      nimExe: fixExecutableFilename(atom.config.get('nim.nimExecutablePath') or 'nim')
      nimSuggestEnabled: atom.config.get 'nim.nimsuggestEnabled'
      lintOnFly: atom.config.get 'nim.onTheFlyChecking'

    @projectManager = new ProjectManager()
    @executor = new Executor @projectManager
    @checkForExes => 
      require('atom-package-deps').install('nim', true)
        .then => @activateAfterChecks(state)
        

  gotoDefinition: (editor) ->
    @executor.execute editor, CommandTypes.DEFINITION, (err, data) ->
      if not err? and data?
        navigateToFile data.path, data.line, data.col, editor

  build: (editor, cb) ->
    @executor.execute editor, CommandTypes.BUILD, (err, result) ->
      if err?
        cb(false) if cb?
      else if result.code != 0
        atom.notifications.addError "Build failed."
        cb(false) if cb?
      else
        atom.notifications.addSuccess "Build succeeded."
        cb(true) if cb?

  activateAfterChecks: (state) ->
    @updateProjectManager()
    
    self = @

    atom.commands.add 'atom-text-editor',
      'nim:goto-definition': (ev) ->
        editor = @getModel()
        return if not editor
        self.gotoDefinition editor

    atom.commands.add 'atom-text-editor',
      'nim:run': (ev) ->
        editor = @getModel()
        return if not editor
        self.build editor

    atom.commands.add 'atom-text-editor',
      'nim:build': (ev) ->
        editor = @getModel()
        return if not editor
        self.build editor

    updateProjectManagerDebounced = debounce 2000, =>
      @checkForExes => @updateProjectManager()

    @subscriptions = new SubAtom()
    @subscriptions.add atom.config.onDidChange 'nim.nimExecutablePath', (path) =>
      @options.nimExe = fixExecutableFilename(path.newValue or 'nim')
      updateProjectManagerDebounced()

    @subscriptions.add atom.config.onDidChange 'nim.nimsuggestExecutablePath', (path) =>
      @options.nimSuggestExe = fixExecutableFilename(path.newValue or 'nimsuggest')
      nsen = atom.config.get 'nim.nimsuggestEnabled'
      if path.newValue == ''
        atom.config.set('nim.nimsuggestEnabled', false) if nsen
      else
        atom.config.set('nim.nimsuggestEnabled', true) if not nsen
      updateProjectManagerDebounced()

    @subscriptions.add atom.config.onDidChange 'nim.nimsuggestEnabled', (enabled) =>
      @options.nimSuggestEnabled = enabled.newValue
      updateProjectManagerDebounced()

    @subscriptions.add atom.config.observe 'nim.useCtrlShiftClickToJumpToDefinition', (enabled) =>
      @options.ctrlShiftClickEnabled = enabled

    @subscriptions.add atom.config.observe 'nim.autocomplete', (value) =>
      @options.autocomplete = if value == 'Always'
        AutoCompleteOptions.ALWAYS
      else if value == 'Only after dot'
        AutoCompleteOptions.AFTERDOT
      else if value == 'Never'
        AutoCompleteOptions.NEVER

    @subscriptions.add atom.config.onDidChange 'nim.projectFilenames', (filenames) =>
      @options.rootFilenames = separateSpaces filenames.newValue
      updateProjectManagerDebounced()

    @subscriptions.add atom.project.onDidChangePaths (paths) =>
      if not arrayEqual paths, @projectManager.projectPaths
        @updateProjectManager()

    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      editorPath = editor.getPath()
      return if not hasExt(editorPath, '.nim') and not hasExt(editorPath, '.nims')

      # For binding ctrl-shift-click
      editorSubscriptions = new SubAtom()
      editorElement = atom.views.getView(editor)
      editorLines = editorElement.shadowRoot.querySelector '.lines'

      editorSubscriptions.add editorLines, 'mousedown', (e) =>
        return unless @options.ctrlShiftClickEnabled 
        return unless e.which is 1 and e.shiftKey and e.ctrlKey
        screenPos = editorElement.component.screenPositionForMouseEvent(e)
        editor.setCursorScreenPosition screenPos
        @gotoDefinition editor
        return false
      editorSubscriptions.add editor.onDidDestroy =>
        editorSubscriptions.dispose()
        @subscriptions.remove(editorSubscriptions)
      @subscriptions.add(editorSubscriptions)

  deactivate: ->
    @subscriptions.dispose()
    @projectManager.destroy()

  nimLinter: -> Linter @executor, @options

  nimAutoComplete: -> AutoCompleter @executor, @options