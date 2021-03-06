Level = require 'models/Level'
LevelComponent = require 'models/LevelComponent'
LevelSystem = require 'models/LevelSystem'
Article = require 'models/Article'
LevelSession = require 'models/LevelSession'
ThangType = require 'models/ThangType'
ThangNamesCollection = require 'collections/ThangNamesCollection'

CocoClass = require 'core/CocoClass'
AudioPlayer = require 'lib/AudioPlayer'
app = require 'core/application'
World = require 'lib/world/world'

# This is an initial stab at unifying loading and setup into a single place which can
# monitor everything and keep a LoadingScreen visible overall progress.
#
# Would also like to incorporate into here:
#  * World Building
#  * Sprite map generation
#  * Connecting to Firebase

module.exports = class LevelLoader extends CocoClass

  constructor: (options) ->
    @t0 = new Date().getTime()
    super()
    @supermodel = options.supermodel
    @supermodel.setMaxProgress 0.2
    @levelID = options.levelID
    @sessionID = options.sessionID
    @opponentSessionID = options.opponentSessionID
    @team = options.team
    @headless = options.headless
    @spectateMode = options.spectateMode ? false

    @worldNecessities = []
    @listenTo @supermodel, 'resource-loaded', @onWorldNecessityLoaded
    @loadLevel()
    @loadAudio()
    @playJingle()
    if @supermodel.finished()
      @onSupermodelLoaded()
    else
      @listenToOnce @supermodel, 'loaded-all', @onSupermodelLoaded

  # Supermodel (Level) Loading

  loadLevel: ->
    @level = @supermodel.getModel(Level, @levelID) or new Level _id: @levelID
    if @level.loaded
      @onLevelLoaded()
    else
      @level = @supermodel.loadModel(@level, 'level').model
      @listenToOnce @level, 'sync', @onLevelLoaded

  onLevelLoaded: ->
    @loadSession()
    @populateLevel()

  # Session Loading

  loadSession: ->
    if @sessionID
      url = "/db/level.session/#{@sessionID}"
    else
      url = "/db/level/#{@levelID}/session"
      url += "?team=#{@team}" if @team

    session = new LevelSession().setURL url
    @sessionResource = @supermodel.loadModel(session, 'level_session', {cache: false})
    @session = @sessionResource.model
    if @opponentSessionID
      opponentSession = new LevelSession().setURL "/db/level.session/#{@opponentSessionID}"
      @opponentSessionResource = @supermodel.loadModel(opponentSession, 'opponent_session', {cache: false})
      @opponentSession = @opponentSessionResource.model

    if @session.loaded
      @session.setURL '/db/level.session/' + @session.id
      @loadDependenciesForSession @session
    else
      @listenToOnce @session, 'sync', ->
        @session.setURL '/db/level.session/' + @session.id
        @loadDependenciesForSession @session
    if @opponentSession
      if @opponentSession.loaded
        @loadDependenciesForSession @opponentSession
      else
        @listenToOnce @opponentSession, 'sync', @loadDependenciesForSession

  loadDependenciesForSession: (session) ->
    if session is @session
      codeLanguage = session.get('codeLanguage') or me.get('aceConfig')?.language or 'python'
      modulePath = "vendor/aether-#{codeLanguage}"
      loading = application.moduleLoader.load(modulePath)
      if loading
        @languageModuleResource = @supermodel.addSomethingResource 'language_module'
        @listenTo application.moduleLoader, 'loaded', (e) ->
          if e.id is modulePath
            @languageModuleResource.markLoaded()
            @stopListening application.moduleLoader
      @addSessionBrowserInfo session

      # hero-ladder games require the correct session team in level:loaded
      team = @team ? @session.get('team')
      Backbone.Mediator.publish 'level:loaded', level: @level, team: team
      Backbone.Mediator.publish 'level:session-loaded', level: @level, session: @session
      @consolidateFlagHistory() if @opponentSession?.loaded
    else if session is @opponentSession
      @consolidateFlagHistory() if @session.loaded
    return unless @level.get('type', true) in ['hero', 'hero-ladder', 'hero-coop']
    @sessionDependenciesRegistered ?= {}
    heroConfig = session.get('heroConfig')
    heroConfig ?= me.get('heroConfig') if session is @session and not @headless
    heroConfig ?= {}
    heroConfig.inventory ?= feet: '53e237bf53457600003e3f05'  # If all else fails, assign simple boots.
    heroConfig.thangType ?= '529ffbf1cf1818f2be000001'  # If all else fails, assign Tharin as the hero.
    session.set 'heroConfig', heroConfig unless _.isEqual heroConfig, session.get('heroConfig')
    url = "/db/thang.type/#{heroConfig.thangType}/version"
    if heroResource = @maybeLoadURL(url, ThangType, 'thang')
      @worldNecessities.push heroResource
    else
      heroThangType = @supermodel.getModel url
      @loadDefaultComponentsForThangType heroThangType
      @loadThangsRequiredByThangType heroThangType

    for itemThangType in _.values(heroConfig.inventory)
      url = "/db/thang.type/#{itemThangType}/version?project=name,components,original,rasterIcon,kind"
      if itemResource = @maybeLoadURL(url, ThangType, 'thang')
        @worldNecessities.push itemResource
      else
        itemThangType = @supermodel.getModel url
        @loadDefaultComponentsForThangType itemThangType
        @loadThangsRequiredByThangType itemThangType
    @sessionDependenciesRegistered[session.id] = true
    if _.size(@sessionDependenciesRegistered) is 2 and @checkAllWorldNecessitiesRegisteredAndLoaded()
      @onWorldNecessitiesLoaded()

  addSessionBrowserInfo: (session) ->
    return unless $.browser?
    browser = {}
    browser['desktop'] = $.browser.desktop if $.browser.desktop
    browser['name'] = $.browser.name if $.browser.name
    browser['platform'] = $.browser.platform if $.browser.platform
    browser['version'] = $.browser.version if $.browser.version
    session.set 'browser', browser
    session.patch()

  consolidateFlagHistory: ->
    state = @session.get('state') ? {}
    myFlagHistory = _.filter state.flagHistory ? [], team: @session.get('team')
    opponentFlagHistory = _.filter @opponentSession.get('state')?.flagHistory ? [], team: @opponentSession.get('team')
    state.flagHistory = myFlagHistory.concat opponentFlagHistory
    @session.set 'state', state

  # Grabbing the rest of the required data for the level

  populateLevel: ->
    thangIDs = []
    componentVersions = []
    systemVersions = []
    articleVersions = []

    flagThang = thangType: '53fa25f25bc220000052c2be', id: 'Placeholder Flag', components: []
    for thang in (@level.get('thangs') or []).concat [flagThang]
      thangIDs.push thang.thangType
      @loadThangsRequiredByLevelThang(thang)
      for comp in thang.components or []
        componentVersions.push _.pick(comp, ['original', 'majorVersion'])

    for system in @level.get('systems') or []
      systemVersions.push _.pick(system, ['original', 'majorVersion'])
      if indieSprites = system?.config?.indieSprites
        for indieSprite in indieSprites
          thangIDs.push indieSprite.thangType

    unless @headless
      for article in @level.get('documentation')?.generalArticles or []
        articleVersions.push _.pick(article, ['original', 'majorVersion'])

    objUniq = (array) -> _.uniq array, false, (arg) -> JSON.stringify(arg)

    worldNecessities = []

    @thangIDs = _.uniq thangIDs
    @thangNames = new ThangNamesCollection(@thangIDs)
    worldNecessities.push @supermodel.loadCollection(@thangNames, 'thang_names')
    @listenToOnce @thangNames, 'sync', @onThangNamesLoaded
    worldNecessities.push @sessionResource if @sessionResource?.isLoading
    worldNecessities.push @opponentSessionResource if @opponentSessionResource?.isLoading

    for obj in objUniq componentVersions
      url = "/db/level.component/#{obj.original}/version/#{obj.majorVersion}"
      worldNecessities.push @maybeLoadURL(url, LevelComponent, 'component')
    for obj in objUniq systemVersions
      url = "/db/level.system/#{obj.original}/version/#{obj.majorVersion}"
      worldNecessities.push @maybeLoadURL(url, LevelSystem, 'system')
    for obj in objUniq articleVersions
      url = "/db/article/#{obj.original}/version/#{obj.majorVersion}"
      @maybeLoadURL url, Article, 'article'
    if obj = @level.get 'nextLevel'  # TODO: update to get next level from campaigns, not this old property
      url = "/db/level/#{obj.original}/version/#{obj.majorVersion}"
      @maybeLoadURL url, Level, 'level'

    unless @headless or @level.get('type', true) in ['hero', 'hero-ladder', 'hero-coop']
      wizard = ThangType.loadUniversalWizard()
      @supermodel.loadModel wizard, 'thang'

    @worldNecessities = @worldNecessities.concat worldNecessities

  loadThangsRequiredByLevelThang: (levelThang) ->
    @loadThangsRequiredFromComponentList levelThang.components

  loadThangsRequiredByThangType: (thangType) ->
    @loadThangsRequiredFromComponentList thangType.get('components')

  loadThangsRequiredFromComponentList: (components) ->
    return unless components
    requiredThangTypes = []
    for component in components when component.config
      if component.original is LevelComponent.EquipsID
        requiredThangTypes.push itemThangType for itemThangType in _.values (component.config.inventory ? {})
      else if component.config.requiredThangTypes
        requiredThangTypes = requiredThangTypes.concat component.config.requiredThangTypes
    for thangType in requiredThangTypes
      url = "/db/thang.type/#{thangType}/version?project=name,components,original,rasterIcon,kind"
      @worldNecessities.push @maybeLoadURL(url, ThangType, 'thang')

  onThangNamesLoaded: (thangNames) ->
    for thangType in thangNames.models
      @loadDefaultComponentsForThangType(thangType)
      @loadThangsRequiredByThangType(thangType)
    @thangNamesLoaded = true
    @onWorldNecessitiesLoaded() if @checkAllWorldNecessitiesRegisteredAndLoaded()

  loadDefaultComponentsForThangType: (thangType) ->
    return unless components = thangType.get('components')
    for component in components
      url = "/db/level.component/#{component.original}/version/#{component.majorVersion}"
      @worldNecessities.push @maybeLoadURL(url, LevelComponent, 'component')

  onWorldNecessityLoaded: (resource) ->
    index = @worldNecessities.indexOf(resource)
    if resource.name is 'thang'
      @loadDefaultComponentsForThangType(resource.model)
      @loadThangsRequiredByThangType(resource.model)

    return unless index >= 0
    @worldNecessities.splice(index, 1)
    @worldNecessities = (r for r in @worldNecessities when r?)
    @onWorldNecessitiesLoaded() if @checkAllWorldNecessitiesRegisteredAndLoaded()

  checkAllWorldNecessitiesRegisteredAndLoaded: ->
    return false unless _.filter(@worldNecessities).length is 0
    return false unless @thangNamesLoaded
    return false if @sessionDependenciesRegistered and not @sessionDependenciesRegistered[@session.id]
    return false if @sessionDependenciesRegistered and @opponentSession and not @sessionDependenciesRegistered[@opponentSession.id]
    true

  onWorldNecessitiesLoaded: ->
    @initWorld()
    @supermodel.clearMaxProgress()
    @trigger 'world-necessities-loaded'
    return if @headless
    thangsToLoad = _.uniq( (t.spriteName for t in @world.thangs when t.exists) )
    nameModelTuples = ([thangType.get('name'), thangType] for thangType in @thangNames.models)
    nameModelMap = _.zipObject nameModelTuples
    @spriteSheetsToBuild ?= []

#    for thangTypeName in thangsToLoad
#      thangType = nameModelMap[thangTypeName]
#      continue if not thangType or thangType.isFullyLoaded()
#      thangType.fetch()
#      thangType = @supermodel.loadModel(thangType, 'thang').model
#      res = @supermodel.addSomethingResource 'sprite_sheet', 5
#      res.thangType = thangType
#      res.markLoading()
#      @spriteSheetsToBuild.push res

    @buildLoopInterval = setInterval @buildLoop, 5 if @spriteSheetsToBuild.length

  maybeLoadURL: (url, Model, resourceName) ->
    return if @supermodel.getModel(url)
    model = new Model().setURL url
    @supermodel.loadModel(model, resourceName)

  onSupermodelLoaded: ->
    return if @destroyed
    console.log 'SuperModel for Level loaded in', new Date().getTime() - @t0, 'ms'
    @loadLevelSounds()
    @denormalizeSession()

  buildLoop: =>
    someLeft = false
    for spriteSheetResource, i in @spriteSheetsToBuild ? []
      continue if spriteSheetResource.spriteSheetKeys
      someLeft = true
      thangType = spriteSheetResource.thangType
      if thangType.loaded and not thangType.loading
        keys = @buildSpriteSheetsForThangType spriteSheetResource.thangType
        if keys and keys.length
          @listenTo spriteSheetResource.thangType, 'build-complete', @onBuildComplete
          spriteSheetResource.spriteSheetKeys = keys
        else
          spriteSheetResource.markLoaded()

    clearInterval @buildLoopInterval unless someLeft

  onBuildComplete: (e) ->
    resource = null
    for resource in @spriteSheetsToBuild
      break if e.thangType is resource.thangType
    return console.error 'Did not find spriteSheetToBuildResource for', e unless resource
    resource.spriteSheetKeys = (k for k in resource.spriteSheetKeys when k isnt e.key)
    resource.markLoaded() if resource.spriteSheetKeys.length is 0

  denormalizeSession: ->
    return if @headless or @sessionDenormalized or @spectateMode
    patch =
      'levelName': @level.get('name')
      'levelID': @level.get('slug') or @level.id
    if me.id is @session.get 'creator'
      patch.creatorName = me.get('name')
    for key, value of patch
      if @session.get(key) is value
        delete patch[key]
    unless _.isEmpty patch
      @session.set key, value for key, value of patch
      tempSession = new LevelSession _id: @session.id
      tempSession.save(patch, {patch: true, type: 'PUT'})
    @sessionDenormalized = true

  # Building sprite sheets

  buildSpriteSheetsForThangType: (thangType) ->
    return if @headless
    # TODO: Finish making sure the supermodel loads the raster image before triggering load complete, and that the cocosprite has access to the asset.
#    if f = thangType.get('raster')
#      queue = new createjs.LoadQueue()
#      queue.loadFile('/file/'+f)
    @grabThangTypeTeams() unless @thangTypeTeams
    keys = []
    for team in @thangTypeTeams[thangType.get('original')] ? [null]
      spriteOptions = {resolutionFactor: SPRITE_RESOLUTION_FACTOR, async: true}
      if thangType.get('kind') is 'Floor'
        spriteOptions.resolutionFactor = 2
      if team and color = @teamConfigs[team]?.color
        spriteOptions.colorConfig = team: color
      key = @buildSpriteSheet thangType, spriteOptions
      if _.isString(key) then keys.push key
    keys

  grabThangTypeTeams: ->
    @grabTeamConfigs()
    @thangTypeTeams = {}
    for thang in @level.get('thangs')
      if @level.get('type', true) is 'hero' and thang.id is 'Hero Placeholder'
        continue  # No team colors for heroes on single-player levels
      for component in thang.components
        if team = component.config?.team
          @thangTypeTeams[thang.thangType] ?= []
          @thangTypeTeams[thang.thangType].push team unless team in @thangTypeTeams[thang.thangType]
          break
    @thangTypeTeams

  grabTeamConfigs: ->
    for system in @level.get('systems')
      if @teamConfigs = system.config?.teamConfigs
        break
    unless @teamConfigs
      # Hack: pulled from Alliance System code. TODO: put in just one place.
      @teamConfigs = {'humans': {'superteam': 'humans', 'color': {'hue': 0, 'saturation': 0.75, 'lightness': 0.5}, 'playable': true}, 'ogres': {'superteam': 'ogres', 'color': {'hue': 0.66, 'saturation': 0.75, 'lightness': 0.5}, 'playable': false}, 'neutral': {'superteam': 'neutral', 'color': {'hue': 0.33, 'saturation': 0.75, 'lightness': 0.5}}}
    @teamConfigs

  buildSpriteSheet: (thangType, options) ->
    if thangType.get('name') is 'Wizard'
      options.colorConfig = me.get('wizard')?.colorConfig or {}
    thangType.buildSpriteSheet options

  # World init

  initWorld: ->
    return if @initialized
    @initialized = true
    @world = new World()
    @world.levelSessionIDs = if @opponentSessionID then [@sessionID, @opponentSessionID] else [@sessionID]
    @world.submissionCount = @session?.get('state')?.submissionCount ? 0
    @world.flagHistory = @session?.get('state')?.flagHistory ? []
    @world.difficulty = @session?.get('state')?.difficulty ? 0
    serializedLevel = @level.serialize(@supermodel, @session, @opponentSession)
    @world.loadFromLevel serializedLevel, false
    console.log 'World has been initialized from level loader.'

  # Initial Sound Loading

  playJingle: ->
    return if @headless
    # Apparently the jingle, when it tries to play immediately during all this loading, you can't hear it.
    # Add the timeout to fix this weird behavior.
    f = ->
      jingles = ['ident_1', 'ident_2']
      AudioPlayer.playInterfaceSound jingles[Math.floor Math.random() * jingles.length]
    setTimeout f, 500

  loadAudio: ->
    return if @headless
    AudioPlayer.preloadInterfaceSounds ['victory']

  loadLevelSounds: ->
    return if @headless
    scripts = @level.get 'scripts'
    return unless scripts

    for script in scripts when script.noteChain
      for noteGroup in script.noteChain when noteGroup.sprites
        for sprite in noteGroup.sprites when sprite.say?.sound
          AudioPlayer.preloadSoundReference(sprite.say.sound)

    thangTypes = @supermodel.getModels(ThangType)
    for thangType in thangTypes
      for trigger, sounds of thangType.get('soundTriggers') or {} when trigger isnt 'say'
        AudioPlayer.preloadSoundReference sound for sound in sounds

  # everything else sound wise is loaded as needed as worlds are generated

  progress: -> @supermodel.progress

  destroy: ->
    clearInterval @buildLoopInterval if @buildLoopInterval
    super()
