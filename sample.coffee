############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     meteor-file-sample-app is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Both client and server

# Default collection name is 'fs'
myData = FileCollection
  resumable: true     # Enable the resumable.js compatible chunked file upload interface
  resumableIndexName: 'test'  # Don't use the default MongoDB index name, which is 94 chars long
  # Define a GET API that uses the md5 sum id files
  http: [
      method: 'get'
      path: '/md5/:md5'
      lookup: (params, query) -> return { md5: params.md5 }
    ,
      method: 'get'
      path: '/repos/*'
      lookup: (params, query) ->
        console.log "Request for file: #{params[0]}"
        return { filename: params[0] }
  ]

############################################################
# Client-only code
############################################################

if Meteor.isClient

  # This assigns a file drop zone to the "file table"
  # once DOM is ready so jQuery can see it
  Template.collTest.onRendered ->
    myData.resumable.assignDrop $('.fileDrop')
    return

  Meteor.startup () ->
    ################################
    # Setup resumable.js in the UI
    # When a file is added
    myData.resumable.on 'fileAdded', (file) ->
      # Keep track of its progress reactively in a session variable
      Session.set file.uniqueIdentifier, 0
      # Create a new file in the file collection to upload to
      myData.insert
          _id: file.uniqueIdentifier    # This is the ID resumable will use
          filename: file.fileName
          contentType: file.file.type
        ,
          (err, _id) ->
            if err
              console.warn "File creation failed!", err
              return
            # Once the file exists on the server, start uploading
            myData.resumable.upload()

      # Update the upload progress session variable
      myData.resumable.on 'fileProgress', (file) ->
        Session.set file.uniqueIdentifier, Math.floor(100*file.progress())

      # Finish the upload progress in the session variable
      myData.resumable.on 'fileSuccess', (file) ->
        Session.set file.uniqueIdentifier, undefined

      # More robust error handling needed!
      myData.resumable.on 'fileError', (file) ->
        console.warn "Error uploading", file.uniqueIdentifier
        Session.set file.uniqueIdentifier, undefined

  # Set up an autorun to keep the X-Auth-Token cookie up-to-date and
  # to update the subscription when the userId changes.
  Tracker.autorun () ->
    userId = Meteor.userId()
    Meteor.subscribe 'allData', userId
    $.cookie 'X-Auth-Token', Accounts._storedLoginToken()

  #####################
  # UI template helpers

  shorten = (name, w = 16) ->
    w += w % 4
    w = (w-4)/2
    if name.length > 2*w
      name[0..w] + '…' + name[-w-1..-1]
    else
      name

  truncateId = (id, length = 6) ->
    if id
      if typeof id is 'object'
        id = "#{id.valueOf()}"
      "#{id.substr(0,6)}…"
    else
      ""

  Template.registerHelper "truncateId", truncateId

  Template.collTest.events
    # Wire up the event to remove a file by clicking the `X`
    'click .del-file': (e, t) ->
      # Just the remove method does it all
      myData.remove {_id: this._id}

    'click #commitButton': (e, t) ->
      console.log "Make Commit"
      Meteor.call 'makeCommit'

    'click #tagButton': (e, t) ->
      console.log "Make Tag"
      Meteor.call 'makeTag'

    'click #addDoc': (e, t) ->
      console.log "Adding a doc"
      Meteor.call "addRecord"

    'click #modDoc': (e, t) ->
      console.log "Modding a doc"
      Meteor.call "modRecord"

    'click #removeDoc': (e, t) ->
      console.log "Removing a doc"
      Meteor.call "removeRecord"

    'click #dbCommit': (e, t) ->
      console.log "Committing Records"
      Meteor.call "makeDbCommit"

  Template.collTest.helpers
    dataEntries: () ->
      # Reactively populate the table
      myData.find({})

    shortFilename: (w = 16) ->
      if this.filename?.length
        shorten this.filename, w
      else
        "(no filename)"

    owner: () ->
      this.metadata?._auth?.owner

    id: () ->
      "#{this._id}"

    link: () ->
      if this.metadata._Git?
        myData.baseURL + "/repos/" + this.filename
      else
        myData.baseURL + "/md5/" + this.md5

    uploadStatus: () ->
      percent = Session.get "#{this._id}"
      unless percent?
        "Processing..."
      else
        "Uploading..."

    formattedLength: () ->
      numeral(this.length).format('0.0b')

    uploadProgress: () ->
      percent = Session.get "#{this._id}"

    isImage: () ->
      types =
        'image/jpeg': true
        'image/png': true
        'image/gif': true
        'image/tiff': true
      types[this.contentType]?

    loginToken: () ->
      Meteor.userId()
      Accounts._storedLoginToken()

    userId: () ->
      Meteor.userId()

############################################################
# Server-only code
############################################################

if Meteor.isServer

  testDb = new Mongo.Collection "testDB"

  git = myData.Git "testRepo"
  dbGit = myData.Git "dbRepo"

  Meteor.startup () ->

    console.log "Checking!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    unless testDb.find({}).count()
      for x in [1..20]
        console.log "Calling addRecord!"
        Meteor.call 'addRecord'
    else
      console.log "Skipping addRecord!"

  # Only publish files owned by this userId, and ignore temp file chunks used by resumable
  Meteor.publish 'allData', (clientUserId) ->

    # This prevents a race condition on the client between Meteor.userId() and subscriptions to this publish
    # See: https://stackoverflow.com/questions/24445404/how-to-prevent-a-client-reactive-race-between-meteor-userid-and-a-subscription/24460877#24460877
    if this.userId is clientUserId
      return myData.find
        'metadata._Resumable':
          $exists: false
        $or: [
            'metadata._auth.owner': this.userId
          ,
            'metadata._auth.owners':
              $in:
                [ this.userId ]
          ]
    else
      return []

  # Don't allow users to modify the user docs
  Meteor.users.deny
    update: () -> true

  # Allow rules for security. Without these, no writes would be allowed by default
  myData.allow
    insert: (userId, file) ->
      # Assign the proper owner when a file is created
      file.metadata = file.metadata ? {}
      file.metadata._auth =
        owner: userId
      true
    remove: (userId, file) ->
      # Only owners can delete
      if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
        return false
      true
    read: (userId, file) ->
      # Only owners can GET file data
      if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
        return false
      true
    write: (userId, file, fields) -> # This is for the HTTP REST interfaces PUT/POST
      # All client file metadata updates are denied, implement Methods for that...
      # Only owners can upload a file
      if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
        return false
      true

  objPath = (hash) ->
    return "objects/#{hash.slice(0,2)}/#{hash.slice(2)}"

  addedFile = (file) ->
    # Check if this blob exists
    myData.findOneStream({ _id: file._id })?.pipe(git._checkFile (err, data, newBlob) =>
      throw err if err
      if newBlob
        myData.findOneStream({ _id: file._id })?.pipe(git._writeFile data, (err, data) =>
          console.log "FileStream written", data
        )
      if data
        myData.update
            _id: file._id
            md5: file.md5
          ,
            $set:
              "metadata.sha1": data.hash
    )

  changedFile = (oldFile, newFile) ->
     if oldFile.md5 isnt newFile.md5
        addedFileJob newFile

  fileObserve = myData.find(
    md5:
      $ne: 'd41d8cd98f00b204e9800998ecf8427e'  # md5 sum for zero length file
    'metadata._Resumable':
      $exists: false
    'metadata._Git':
      $exists: false
  ).observe(
    added: addedFile
    changed: changedFile
  )

  makeFileTree = (collection, query) ->
    tree = collection.find(query).map (f) ->
      name: f.filename
      mode: collection.gbs.gitModes.file
      hash: f.metadata.sha1
    return tree

  Meteor.methods
    addRecord: () ->
      testDb.insert
        a: Math.floor 100*Math.random()
        b: Math.floor 100*Math.random()
      console.log "Added! Count is now: ", testDb.find({}).count()

    modRecord: () ->
      d = testDb.findOne({})
      r = Math.random()
      if r < 1/3
        d.c = Math.floor 100*Math.random()
      else if r < 2/3
        d.b = Math.floor 100*Math.random()
      else
        d.a = Math.floor 100*Math.random()
      testDb.update d._id, d
      console.log "Modded! Count is now: ", testDb.find({}).count()

    removeRecord: () ->
      testDb.remove testDb.findOne({})
      console.log "Removed! Count is now: ", testDb.find({}).count()

    makeDbCommit: () ->
      treeData = dbGit._makeDbTree testDb, {}
      commit =
        author:
          name: "Vaughn Iverson"
          email: "vsi@uw.edu"
        tree: treeData.result.hash
        message: "Test commit\n"
      if parent = dbGit._readRef 'refs/heads/master'
        commit.parent = parent
      data = dbGit._writeCommit commit
      dbGit._writeRef 'refs/heads/master', data.result.hash
      return data

    makeCommit: () ->
      tree = makeFileTree(myData,
        md5:
          $ne: 'd41d8cd98f00b204e9800998ecf8427e'  # md5 sum for zero length file
        'metadata._Resumable':
          $exists: false
        'metadata._Git':
          $exists: false
      )
      treeData = git._writeTree tree
      commit =
        author:
          name: "Vaughn Iverson"
          email: "vsi@uw.edu"
        tree: treeData.result.hash
        message: "Test commit\n"
      if parent = git._readRef 'refs/heads/master'
        commit.parent = parent
      data = git._writeCommit commit
      git._writeRef 'refs/heads/master', data.result.hash
      return data

    makeTag: () ->
      # Tag the current master branch commit
      commit = git._readRef 'refs/heads/master'
      unless commit
        commit = Meteor.call('makeCommit').result.hash
      tagName = "TAG_#{Math.floor(Math.random()*10000000).toString(16)}"
      tag =
        object: commit
        type: 'commit'
        tag: tagName
        tagger:
          name: "Vaughn Iverson"
          email: "vsi@uw.edu"
        message: "Test tag\n"
      data = git._writeTag tag
      return data
