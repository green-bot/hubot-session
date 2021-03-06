# Description:
#   Connects greenbot to Telnet
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

Telnet = require('telnet')
ShortUUID = require 'shortid'

module.exports = (robot) ->
  Telnet.createServer((client) ->
    sessionId = ShortUUID.generate()
    client.on 'data', (b) ->
      msg =
        dst: '12183255075'
        src: 'telnet'
        txt: b.toString()
      robot.emit 'telnet:ingress', msg
      return

    robot.on "telnet:egress:telnet", (txt) ->
      client.write new Buffer txt + "\n"

    return
  ).listen 3002
