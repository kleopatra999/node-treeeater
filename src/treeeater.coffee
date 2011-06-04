{ spawn } = require 'child_process'
BufferStream = require 'bufferstream'
EventEmitter = (require 'events').EventEmitter
git_commands = (require './git-commands.js').commands
Path = require 'path'

debug_log = (what...) ->
    console.log 'DEBUG:', (""+x for x in what).join(' ')

class Git
    constructor: (@opts) ->
        for cmd in git_commands
            func = cmd.replace /-/g, '_'
            this[func] = do (cmd) => (opts..., cb) =>
                [opts, cb] = @opts_cb opts, cb
                @spawn 'git', c: 'color.ui=never', cmd, opts, cb

    opts2args: (opts) =>
        args = []
        for k,v of opts
            if k.length > 1
                if v != null
                    args.push "--#{k}=#{v}"
                else
                    args.push "--#{k}"
            else if k.length == 1
                if v != null
                    args.push "-#{k}"
                    args.push "#{v}"
                else
                    args.push "-#{k}"
            else args.push "--"
        args

    # version # returns the git version string
    # opts... # git --version options
    version: (opts..., cb) =>
        [opts, cb] = @opts_cb opts, cb
        @spawn 'git', '--version', opts, cb

    # commits             # serves commits as parsed from git log
    # opts...             # git log options
    # [cb]: ([object]) -> # gets all the commits
    # returns: EventEmitter commit: object, end
    commits: (opts..., cb) =>
        [opts, cb] = @opts_cb opts, cb
        @log opts,
            raw: null
            pretty: 'raw'
            numstat: null
            'no-color': null
            'no-abbrev': null
            parser: new CommitsParser
            , cb

    # tree                # opts should contain a revision like HEAD
    # opts...             # git ls-tree options
    # [cb]: ([object]) -> # gets all the tree objects
    # returns: EventEmitter tree: object, end
    trees: (opts..., cb) =>
        [opts, cb] = @opts_cb opts, cb
        @ls_tree '-l', '-r', '-t', opts, parser: new TreesParser, cb

    # tree_hierachy
    # transforms the output of @tree into a correct tree hierachy
    # * the returned tree and sub-trees are array-iterable to get inside objects
    # * the returned tree and sub-trees have .contents which
    #   map a basename to an object
    # * the returned tree has a .all which map the full paths of all objects
    #   and sub-objects to the object
    tree_hierachy: (trees) =>
        trees = trees[0..]
        path_tree_map = {}
        hierachy = []
        hierachy.contents = {}
        hierachy.all = {}
        n = trees.length * 2
        while trees.length
            obj = trees.pop()
            if obj.type == 'tree'
                # so you can array-iterate of a tree object to get its contents
                tree = []
                tree.contents = {}
                tree[k] = v for k, v of obj
                obj = tree
                # a tree is put into path_tree_map for easy lookup
                path_tree_map[tree.path] = tree
            # easy access to dir- and basename
            obj.dirname = Path.dirname obj.path
            obj.basename = Path.basename obj.path
            # easy lookup if you have the full path via .all
            hierachy.all[obj.path] = obj
            # push into root directory
            if obj.dirname == '.'
                hierachy.push obj
                hierachy.contents[obj.basename] = obj
            # push into some directory
            else if obj.dirname of path_tree_map
                dir = path_tree_map[obj.dirname]
                dir.push obj
                dir.contents[obj.basename] = obj
            # queue it back so the needed directory is there next time
            else trees = [obj].concat trees
            # if the needed directory is not there next time,
            # we are in an infinite loop, so we through an error after we have
            # seen too much ^^
            if !(n -= 1) and trees.length
                throw "#{Path.dirname(trees[0].path)} missing #{n} #{trees.length}"
        hierachy

    # commit_tree_hierachy      # annotates blobs with corresponding commits
    #                             in a tree_hierachy INPLACE
    # tree_hierachy             # the return of tree_hierachy
    # opts...                   # @commits options
    # [cb]: (tree_hierachy) ->  # gets the tree_hierachy
    # returns: EventEmitter blob: object, end # emits newly annotated blob
    commit_tree_hierachy: (tree_hierachy, opts..., cb) =>
        [ opts, cb ] = @opts_cb opts, cb
        todo = 0
        blobs = {}
        for path, blob of tree_hierachy.all
            continue if blob.type != 'blob'
            blobs[path] = blob
            todo += 1
        ee = new EventEmitter
        commits = @commits opts
        commits.on 'item', (commit) =>
            if todo
                for path of commit.changes
                    if path of blobs
                        blobs[path].commit = commit
                        ee.emit 'item', blobs[path]
                        delete blobs[path]
                        todo -= 1
        commits.on 'close', =>
            ee.emit 'close'
            cb? tree_hierachy
        ee

    # cat               # cats the content of an blob as a Buffer
    # treeish: path/{revision: path} # default revision is HEAD
    # opts...           # git cat-file options
    cat: (treeish, opts..., cb) =>
        if typeof treeish == 'string'
            path = treeish
            revision = 'HEAD'
        else for k, v of treeish
            path = v
            revision = k
        [ opts, cb ] = @opts_cb opts, cb
        @cat_file '-p', opts, "#{revision}:#{path}", chunked: true, cb

    # diffs             # returns diff objects
    # opts...           # git diff options
    diffs: (opts..., cb) =>
        [opts, cb] = @opts_cb opts, cb
        # TODO when the parser supports it: --full-index
        @diff 'no-color': null, opts, parser: new DiffsParser, cb

    # spawn             # mostly like child_process.spawn
    # command: string
    # opts: [...]       # command options and special options like
                        # documented in child_process.spawn#options
                        # or { chunked: true } to disable line splits
    # [cb]: (string) -> # gets all the text
    # returns: EventEmitter line: string, end
    spawn: (command, opts..., cb) =>
        [opts, cb] = @opts_cb opts, cb
        # split into args and filtered options
        args = []
        options = {}
        special = ['cwd', 'env', 'customFds', 'setsid', 'chunked', 'parser',
            'caching']
        i = 0 # i am pushing stuff into opts inside the loop, thats why i need i
        while i < opts.length
            arg = opts[i]
            # to mix single strings and arrays in the arguments
            if Array.isArray(arg)
                opts.push.apply opts, arg # thats the pushing i is needed for
            else if typeof arg == 'object'
                # the options filter for special options
                filtered = {}
                for k, v of arg
                    if k in special
                        options[k] = v
                    else
                        filtered[k] = v
                args = args.concat @opts2args(filtered)
            else if typeof arg is 'string'
                args.push arg
            else unless typeof arg is 'undefined'
                throw Error "wrong arg #{arg} in opts"
            i++
        # cache or spawn
        cache_key = command+' '+args.join(' ')+'  #'+
            [" #{k}: #{v}" for k,v of options]
        # TODO cache lookup
        # spawn and pipe through BufferStream
        debug_log 'spawn:', cache_key
        buffer = new BufferStream
        child = spawn command, args, options
        child.stderr.on 'data', debug_log
        process.once 'exit', child.kill
        child.on 'exit', () ->
            process.removeListener 'exit', child.kill
            delete child
        child.stdout.pipe buffer
        @output buffer, options.chunked, options.parser, cb

    opts_cb: (opts, cb) =>
        opts ?= []
        opts.push @opts
        if typeof cb != 'function'
            opts.push cb
            cb = undefined
        [opts, cb]

    output: (buffer, chunked, parser, cb) =>
        if chunked
            throw 'you cant use a parser in chunked mode!' if parser
            if cb
                buffer.on 'close', () -> cb buffer.buffer
            else
                buffer.disable()
        else
            if parser
                # extra EventEmitter needed to circumvent emitting 'close'
                # earlier than the last emit 'item'
                ee = new EventEmitter
                buffer.split '\n', (l,t) ->
                    item = parser.line l.toString()
                    (ee.emit 'item', item) if item
                buffer.on 'close', ->
                    item = parser.end()
                    (ee.emit 'item', item) if item
                    ee.emit 'close'
                if cb
                    items = []
                    ee.on 'item', (item) -> items.push item
                    ee.on 'close', -> cb items
                return ee
            else
                buffer.split '\n', (l,t) -> buffer.emit 'item', l.toString()
                if cb
                    items = []
                    buffer.on 'item', (item) -> items.push item
                    buffer.on 'close', -> cb items
        buffer

# see CommitsParser to see an example of the usage
# a possible error in usage is a wrong regex at index 0 which results surely in
# a TypeError cause of setting a property of null
class ItemsParser
    constructor: (@regexes) ->
        @item = null
    end: () => @item unless @no_match
    line: (line) =>
        return_item = null
        matched = false
        for [ regex, func ], i in @regexes
            match = line.match regex
            if match
                matched = true
                if i == 0
                    return_item = @item
                    @item = {}
                func.call this, match
        unless matched
            debug_log "ItemsParser.line - unknown line:", line
        return_item

class CommitsParser extends ItemsParser
    constructor: () -> @regexes = regexes
    regexes = [
        [/^commit ([0-9a-z]+)/, (match) ->
            @item.sha = match[1]]
        [/^tree ([0-9a-z]+)/, (match) ->
            @item.tree = match[1]]
        [/^parent ([0-9a-z]+)/, (match) ->
            (@item.parents ?= []).push match[1]]
        [/^author (\S+) (\S+) (\d+) (\S+)/, (match) ->
            # TODO take timezone into account
            [ _, name, email, secs, timezone ] = match
            date = new Date secs * 1000
            @item.author = { name, email, date }]
        [/^committer (\S+) (\S+) (\d+) (\S+)/, (match) ->
            # TODO take timezone into account
            [ _, name, email, secs, timezone ] = match
            date = new Date secs * 1000
            @item.committer = { name, email, date }]
        [/^\s\s\s\s(.*)/, (match) ->
            @item.message = (@item.message or "") + match[1]
            @item.short_message = @item.message[...80]]
        [/^:(\S+) (\S+) ([0-9a-z]+) ([0-9a-z]+) (.+)\t(.+)/, (match) ->
            [ _, modea, modeb, shaa, shab, status, path ] = match
            (@item.changes ?= {})[path] = { modea, modeb, shaa, shab, status }]
        [/^([0-9-]+)\s+([0-9-]+)\s+(.+)/, (match) ->
            [ _, plus, minus, path ] = match
            (@item.numstats ?= {})[path] = { plus, minus }]
        [/^$/, ->]
    ]

class TreesParser extends ItemsParser
    constructor: () -> @regexes = regexes
    regexes = [
        [/^(\S+) (\S+) (\S+)\s+(\S+)\s+(.+)/, (match) ->
            [ _, mode, type, sha, size, path ] = match
            @item = { mode, type, sha, size, path }]]

class DiffsParser extends ItemsParser
    constructor: () -> @regexes = regexes
    set_by_list: (names..., match) ->
        for name, i in names
            @item[name] = match[i] if name
    regexes = [
        [/^diff (.+) a\/(.+) b\/(.+)/, (match) ->
            @set_by_list null, 'type', 'src', 'dst', match]
        [/^@.*/, (match) ->
            (@item.chunks ?= []).push { head: match[0], lines: [] }]
        [/^[ \-+](.*)/, (match) ->
            # "?" is a fix for "+++"/"---" lines in the header
            @item.chunks?[-1..][0].lines.push match[1]]
        [//, ->]
    ]

module.exports = Git

