# Description:
#   Handles session aware dialogs.
#
# Dependencies:
#
# Configuration:
#
# Commands:
#
# Author:
#   Thomas Howe - ghostofbasho@gmail.com
#

_ = require('underscore')
Async = require('async')
ChildProcess = require("child_process")
Events = require('events')
LanguageFilter = require('watson-translate-stream')
Mailer = require("nodemailer")
Os = require("os")
Pipe = require("multipipe")
Promise = require('node-promise')
ShortUUID = require 'shortid'
Stream = require('stream')
Url = require("url")
Us = require("underscore.string")
Util = require('util')

# Setup the connection to the database
connectionString = process.env.MONGO_URL or 'localhost/greenbot'
Db = require('monk')(connectionString)
Rooms = Db.get('Rooms')
Sessions = Db.get('Sessions')

module.exports = (robot) ->
  # Helper functions
  info = (text) ->
    console.log text

  genSessionKey = (msg) ->
    msg.src + "_" + msg.dst

  cleanText = (text) ->
    return "" unless text
    text.trim().toLowerCase()

  msg_text = (msg) ->
    msg.txt

  visitor_name = (msg) ->
    msg.src.toLowerCase()

  isJson = (str) ->
    # When a text message comes from a session, if it's a valid JSON
    # string, we will treat it as a command or data. This function
    # allows us to figure that out.
    try
      JSON.parse str
    catch e
      return false
    true

  sessionUpdate = Async.queue (session, callback) ->
    information = session.information()
    sessionId = session.sessionId
    cb = (err, session) ->
      info "Threw error on database update #{err}" if err
      callback()

    Sessions.findOne {sessionId: sessionId}, (err, session) ->
      if session?
        Sessions.findAndModify {
          query:
            sessionId: sessionId
          update:
            information
          options:
            new: true
          }, cb
      else
        info 'Creating a new session'
        information.createdAt = Date.now()
        Sessions.insert information, cb

  class Session
    @active = []

    @findOrCreate: (msg, cb) ->
      # All messages that come from the network end up here.
      session_name = genSessionKey(msg)
      session = @active[session_name]
      if session
        # We already have a session, so send it off.
        session.ingressMsg(msg.txt)
      else
        # No session active. Kick one off.
        name = process.env.DEV_ROOM_NAME or msg.dst.toLowerCase()
        keyword = cleanText(msg.txt)
        Rooms.findOne {name: name, keyword: keyword}, (err, room) ->
          info "Can't find #{name}:#{keyword}" if err
          if room
            info "Found room #{name}, starting session"
            new Session(msg, room, cb)
          return if room or err

          # No room and keyword combination matched
          # Return the default if there's one.
          info 'No room/keyword found. Check for default'
          Rooms.findOne {name: name, default: true}, (err, room) ->
            if room
              info "Found room #{name}, starting session"
              new Session(msg, room, cb)
            else
              info 'No default room, no matching keyword. Fail.'


    constructor: (@msg, @room, @cb) ->
      # The variables that make up a Session
      @transcript = []
      @src = @msg.src
      @dst = @msg.dst.toLowerCase()
      @sessionKey = genSessionKey(@msg)
      @sessionId = ShortUUID.generate()
      Session.active[@sessionKey] = @
      @automated = true
      @processStack = []

      # Assemble the @command, @arguments, @opts
      @createSessionEnv()
      langQ = Sessions.findOne({src: @src}, {sort: {updatedAt: -1}})
      langQ.error = (err) ->
        info 'Mongo error in fetch language : ' + err
      langQ.then (session) =>
        info 'Session query complete : ' + Util.inspect session
        if session?.lang?
          @lang = session.lang
        else
          @lang = process.env.DEFAULT_LANG or 'en'
        info 'Kicking off process with lang ' + @lang
        @kickOffProcess(@command, @arguments, @opts, @lang)

    kickOffProcess : (command, args, opts, lang) ->
      # Start the process, connect the pipes
      info 'Kicking off process ' + command
      @process = ChildProcess.spawn(command, args, opts)
      info "New process : #{@process.pid}"
      @language = new LanguageFilter('en', lang)
      jsonFilter = @createJsonFilter()
      @ingressProcessStream = Pipe(@language.ingressStream, @process.stdin)
      @egressProcessStream = Pipe(@process.stdout, jsonFilter,
                                  @language.egressStream)

      @egressProcessStream.on "readable", () =>
        # Send the output of the egress stream off to the network
        info 'Data available for reading'
        @egressMsg @egressProcessStream.read()

      @egressProcessStream.on "end", (code, signal) =>
        # When the egress stream closes, the session ends.
        # If process stack empty, end
        nextProcess = @processStack.shift()
          # If process stack has element, run that.
        if nextProcess?
          info 'Process ended. Starting a new one.'

          # Unpipe the old stuff
          @process.stdout.unpipe()
          {command, args, opts, lang} = nextProcess
          @kickOffProcess(command, args, opts, lang)
        else
          info 'Process ended.'
          @endSession()

      @egressProcessStream.on "error", (err) ->
        info "Error thrown from session"
        info err
      @process.stderr.on "data", (buffer) ->
        info "Received from stderr #{buffer}"
      @language.on "langChanged", (oldLang, newLang) =>
        info "Language changed, restarting : #{oldLang} to #{newLang}"
        @egressProcessStream.write("Language changed, restarting conversation.")
        info "Restarting session."
        @lang = newLang
        nextProcess =
          command: @command
          args: @arguments
          opts: @opts
          lang: @lang
        @processStack.push nextProcess
        @process.kill()

    createSessionEnv: () ->
      if @isOwner()
        info "Running as the owner"
        if @room.test_mode is true
          @room.test_mode = false
          Db.update 'Rooms', @room.objectId,
            { test_mode: false }, (err, response) ->
            if err
              info "Error trying to turn off test mode : #{err}"
          @arguments  = @room.default_cmd.split(" ")
        else
          @arguments  = @room.owner_cmd.split(" ")
      else
        info "Running as a visitor"
        @arguments  = @room.default_cmd.split(" ")
      @command = @arguments[0]
      @arguments.shift()
      @env = @cmdSettings()
      @env.INITIAL_MSG = @msg.txt
      @opts =
        cwd: @room.default_path
        env: @env


      # Now save it in the database
    updateDb: () ->
      info "Updating session #{@sessionId}"
      sessionUpdate.push @

    information: () ->
      transcript:     @transcript
      src:            @src
      dst:            @dst
      sessionKey:     @sessionKey
      sessionId:      @sessionId
      roomId:         @room.objectId
      collectedData:  @collectedData
      updatedAt:      Date.now()
      lang:           @lang


    endSession: () ->
      info "Ending and recording session #{@sessionId}"
      robot.emit 'session:ended', @sessionId
      delete Session.active[@sessionKey]

    cmdSettings: () ->
      env_settings = _.clone(process.env)
      env_settings.SESSION_ID = @sessionId
      env_settings.SRC = @src
      env_settings.DST = @dst
      env_settings.ROOM_OBJECT_ID = @room.objectId
      for attrname of @room.settings
        env_settings[attrname] = @room.settings[attrname]
      return env_settings

    isOwner: () ->
      if @room.owners? and @src in @room.owners
        info "Running session #{@sessionId} as the owner"
        true
      else
        info "Running session #{@sessionId} as a visitor"
        false


    egressMsg: (text) =>
      if text
        lines = text.toString().split("\n")
      else
        lines = []
      for line in lines
        line = line.trim()
        if line.length > 0
          @cb @src, line
          info "#{@sessionId}: #{@room.name}: #{line}"
          @transcript.push { direction: 'egress', text: line}
          @updateDb()

    ingressMsg: (text) =>
      if cleanText(text) == '/human'
        @automated = false
        robot.emit 'livechat:newsession', @information()
      if @automated
        @ingressProcessStream.write("#{text}\n")
      else
        robot.emit 'livechat:ingress', @information(), text
      @transcript.push { direction: 'ingress', text: text}
      info "#{@sessionId}: #{@src}: #{text}"
      @updateDb()

    createJsonFilter: () =>
      # Filter out JSON as it goes through the system
      jsonFilter = new Stream.Transform()
      jsonFilter._transform = (chunk, encoding, done) ->
        info "Filtering JSON"
        lines = chunk.toString().split("\n")
        for line in lines
          do (line) ->
            if isJson(line)
              jsonFilter.emit 'json', line
            else
              jsonFilter.push(line)
        done()
      jsonFilter.on 'json', (line) =>
        # If the message is JSON, treat it as if it were collected data
        info "Remembering #{line}"
        @collectedData = JSON.parse line
        @updateDb()
      return jsonFilter


  robot.on 'telnet:ingress', (msg) ->
    Session.findOrCreate msg, (dst, txt) ->
      robot.emit "telnet:egress:#{dst}", txt

  robot.on 'slack:ingress', (msg) ->
    Session.findOrCreate msg, (dst, txt) ->
      robot.emit "slack:egress", dst, txt

  robot.hear /(.*)/i, (hubotMsg) ->
    dst = hubotMsg.message.room.toLowerCase()
    src = hubotMsg.message.user.name.toLowerCase()
    msg =
      dst: dst
      src: src
      txt: hubotMsg.message.text
    Session.findOrCreate msg, (src, txt) ->
      user = robot.brain.userForId dst, name: src
      robot.send user, txt

  robot.on 'livechat:egress', (sessionKey, text) ->
    console.log "Received #{text} for #{sessionKey}"
