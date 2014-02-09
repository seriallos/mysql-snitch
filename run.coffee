# Process to run queries on valuable tables and alert if they change

os = require "os"

_ = require "underscore"
mysql = require "mysql"
{diff} = require "deep-diff"
{CronJob} = require "cron"
HipChat = require "node-hipchat"
email = require "emailjs"
config = require "config"
bunyan = require "bunyan"
bsyslog = require "bunyan-syslog"

# constants, globals

FAIL_FAST = config.FAIL_FAST

gCronJobs = []

changeNiceNames =
  update: "Record has been updated"
  insert: "Record has been inserted"
  delete: "Record has been deleted"

# set up logging to syslog

bstream = bsyslog.createBunyanStream
  type: 'sys'
  facility: bsyslog.local0

log = bunyan.createLogger
  name: "snitch"
  streams: [{
    level: "info"
    type: "raw"
    stream: bstream
  }
  {
    level: "info"
    stream: process.stdout
  }]

log.info "Starting up"

# unroll config into context hashes for CronJob
getJobs = ( config ) ->
  jobs = []
  for db_name, details of config.databases
    for check_name, check of details.checks
      context =
        name: "#{db_name}:#{check_name}"
        conn: details.conn
        cron: check.cron
        query: check.query
        prevState: null
      jobs.push context
  return jobs

# stop all jobs
killJobs = () ->
  for job in gCronJobs
    job.stop()

# do the query results differ?
stateChanged = ( curState, prevState ) ->
  return not _.isEqual curState, prevState

# runJob determines state by the context provided to the CronJob
runJob = () ->
  # store this as a local variable so we can reference in the db.query
  job = @

  log.info "Running #{job.name}"

  # build up and tear down mysql connection on every job run.
  # this keeps things simpler - don't have to worry about long-running
  # connections clogging connection limits or getting terminated due to time
  # limits.
  db = mysql.createConnection @conn
  db.connect()
  db.query @query, ( err, rows, fields ) ->
    if err
      # log error, continue processing
      log.error "MySQL ERROR on #{job.name} - #{err}"

      # do not change previous state
    else

      # find ID field
      if _.first( rows )?.id?
        idField = 'id'
      else if fields?
        idField = fields[0]?.name
      else
        idField = null

      # transform rows array into records object
      records = {}
      for row in rows
        records[ row[ idField ] ] = row

      if job.prevState is null
        # future feature: load previously persisted state here in case of
        # restart
        log.info "#{job.name} - First load"
      else
        if stateChanged records, job.prevState
          log.info "#{job.name} - Query results have changed, notifying"
          notify records, job.prevState, job
      job.prevState = records
  db.end()

# compare result sizes to determine type of change
# returns 'update', 'insert', or 'delete'
changeType = ( curState, prevState ) ->
  curLen = _.size curState
  prevLen = _.size prevState
  if curLen == prevLen
    type = "update"
  else if curLen > prevLen
    type = "insert"
  else
    type = "delete"
  return type

# human readable output of a single diff in results
diffNiceName = ( diff, curState ) ->
  html = ""
  if diff.kind == 'E'
    html = "Record #{diff.path[0]}: "
    html += "<strong>#{diff.path[1]}</strong> changed"
    html += "<ul>"
    html += " <li>From: #{diff.lhs}</li>"
    html += " <li>To: #{diff.rhs}</li>"
    html += "</ul>"

  else if diff.kind == 'N'
    html += "New record with ID #{diff.path[0]}!"
    html += "<ul>"
    for own field, value of diff.rhs
      html += "<li>#{field} = #{value}</li>"
    html += "</ul>"

  else if diff.kind == 'D'
    html += "Deleted record index #{diff.path[0]}"
    html += "<ul>"
    for own field, value of diff.lhs
      html += "<li>#{field} = #{value}</li>"
    html += "</ul>"

  return html

# format result diff into HTML readable form
htmlMessage = ( curState, prevState, jobContext ) ->
  html = "<strong>#{jobContext.name} alert! Changes detected!</strong><br/>"
  html += "<ul>"
  diffs = diff prevState, curState
  for d in diffs
    niceName = diffNiceName d, curState
    html += "<li>#{niceName}</li>"
  html += "</ul>"
  return html

# generate HTML, send off to all notification functions
notify = ( curState, prevState, jobContext ) ->
  html = htmlMessage curState, prevState, jobContext
  notifyHipchat html, jobContext
  notifyEmail html, jobContext

# send an alert to hipchat
notifyHipchat = ( html, context, callback ) ->
  if config.hipchat?.token?
    hipchat = new HipChat config.hipchat.token

    if html.length > 10000
      html = "Message longer than 10000 characters!<br/>"
      html += "See server logs for full list of changes<br/>"
      html += html.substring( 0, 9000 )

    options =
      message: html
      room: config.hipchat.room
      from: config.hipchat.from
      notify: config.hipchat.notify
      color: config.hipchat.color

    hipchat.postMessage options, ( response, error ) ->
      if error
        log.error "Hipchat notification error: #{error}"
      if callback
        callback( response, error )

# send an alert to email
notifyEmail = ( html, context, callback ) ->
  if config.email?.to?
    server = email.server.connect config.email.server

    # add email footer
    html += "<br/><br/>"
    html += "Sent by MySQL-Snitch"
    html += "Process running on #{os.hostname()}"

    sendOpts =
      text: "Email sent in HTML only, no plaintext version available"
      from: config.email.from
      to:   config.email.to.join( ', ' )
      bcc:  config.email.bcc?.join ', '
      subject: "Snitch: #{context.name}"
      attachment: [
        {data: html, alternative: true}
      ]

    server.send sendOpts, ( err, message ) ->
      if err
        log.error "Email error! #{err}"
        if callback
          callback err, message

# not the best method of handling errors but it'll do for now
process.on 'uncaughtException', ( err ) ->
  if FAIL_FAST
    killJobs()
  log.error err.stack
  # attempt to notify HipChat of the fatal error
  msg = "<strong>Uncaught exception for mysql-snitch "
  msg += " running on #{os.hostname()}</strong><br/>"
  msg += "<code>#{err.stack}</code>"
  notifyHipchat msg, null, ( hipResp, hipErr ) ->
    if FAIL_FAST
      # only kill once notification has been sent out
      log.error "FAIL_FAST is true, killing the process"
      process.exit 1


# first thing, build a list of contexts that we can pass to cron jobs
# this basically unrolls the config object in such a way as proper data is
# available to the cronned functions
jobs = getJobs( config )

for job in jobs
  job_config =
    cronTime: job.cron
    start: true
    context: job
    onTick: runJob
  # track all jobs globally in case we need to stop them later
  gCronJobs.push( new CronJob(  job_config ) )

log.info "Jobs loaded and started"

# jobs have been scheduled and they will fire when their cron times roll around
