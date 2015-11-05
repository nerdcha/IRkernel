#' @include execution.r
NULL

Kernel <- setRefClass(
    'Kernel',
    fields  = list(
        connection_info = 'list',
        zmqctx          = 'externalptr',
        sockets         = 'list',
        executor        = 'Executor'),
    methods = list(

hb_reply = function() {
    data <- receive.socket(sockets$hb, unserialize = FALSE)
    send.socket(sockets$hb, data, serialize = FALSE)
},

#'<brief desc>
#'
#'<full description>
#' @param msg_lst <what param does>
#' @export
sign_msg = function(msg_lst) {
    concat <- unlist(msg_lst)
    hmac(connection_info$key, concat, 'sha256')
},
#'<brief desc>
#'
#'<full description>
#' @param parts <what param does>
#' @import rjson
#' @export
wire_to_msg = function(parts) {
    i <- 1
    #print(parts)
    while (!identical(parts[[i]], charToRaw('<IDS|MSG>'))) {
        i <- i + 1
    }
    if (!identical(connection_info$key, '')) {
        signature <- rawToChar(parts[[i + 1]])
        expected_signature <- sign_msg(parts[(i + 2):(i + 5)])
        stopifnot(identical(signature, expected_signature))
    }
    header        <- fromJSON(rawToChar(parts[[i + 2]]))
    parent_header <- fromJSON(rawToChar(parts[[i + 3]]))
    metadata      <- fromJSON(rawToChar(parts[[i + 4]]))
    content       <- fromJSON(rawToChar(parts[[i + 5]]))
    if (i > 1) {
        identities <- parts[1:(i - 1)]
    } else {
        identities <- NULL
    }
    list(
        header        = header,
        parent_header = parent_header,
        metadata      = metadata,
        content       = content,
        identities    = identities)
},
#'<brief desc>
#'
#'<full description>
#' @param msg <what param does>
#' @export
msg_to_wire = function(msg) {
    #print(msg)
    bodyparts <- list(
        charToRaw(toJSON(msg$header,        auto_unbox = TRUE)),
        charToRaw(toJSON(msg$parent_header, auto_unbox = TRUE)),
        charToRaw(toJSON(msg$metadata,      auto_unbox = TRUE)),
        charToRaw(toJSON(msg$content,       auto_unbox = TRUE)))
    
    signature <- sign_msg(bodyparts)
    c(
        msg$identities,
        list(charToRaw('<IDS|MSG>')),
        list(charToRaw(signature)),
        bodyparts)
},
#'<brief desc>
#'
#'<full description>
#' @param msg_type <what param does>
#' @param  parent_msg <what param does>
#' @export
new_reply = function(msg_type, parent_msg) {
    header <- list(
        msg_id   = UUIDgenerate(),
        username = parent_msg$header$username, 
        session  = parent_msg$header$session,
        msg_type = msg_type,
        version  = '5.0')
    
    list(
        header        = header,
        parent_header = parent_msg$header,
        identities    = parent_msg$identities,
        # Ensure this is {} in JSON, not []
        metadata      = namedlist())
},
#'<brief desc>
#'
#'<full description>
#' @param msg_type <what param does>
#' @param  parent_msg <what param does>
#' @param  socket <what param does>
#' @param  content <what param does>
#' @export
send_response = function(msg_type, parent_msg, socket_name, content) {
    msg <- new_reply(msg_type, parent_msg)
    msg$content <- content
    socket <- sockets[[socket_name]]
    send.multipart(socket, msg_to_wire(msg))
},
#'<brief desc>
#'
#'<full description>
#' @param  <what param does>
#' @export
handle_shell = function() {
    print("Receiving shell message")
    parts <- receive.multipart(sockets$shell)
    msg <- wire_to_msg(parts)
    print(msg)
    switch(
        msg$header$msg_type,
        execute_request     = executor$execute(msg),
        kernel_info_request = kernel_info(msg),
        history_request     = history(msg),
        complete_request    = complete(msg),
        is_complete_request = is_complete(msg),
        shutdown_request    = shutdown(msg),
        print(c('Got unhandled msg_type:', msg$header$msg_type)))
},
#'Checks whether the code in the rest is complete
#'
#' @param  request the is_complete request 
#' @export
is_complete = function(request) {
    code <- request$content$code
    message <- tryCatch({
        parse_all(code)
        # the code compiles, so we are complete (either no code at all / only
        # comments or syntactically correct code)
        'complete'
    }, error = function(e) e$message)
    
    # One of 'complete', 'incomplete', 'invalid', 'unknown'
    status <- if (message == 'complete') {
        # syntactical complete code
        'complete'
    } else if (grepl('unexpected end of input', message)) {
        # missing closing parenthesis
        'incomplete'
    } else if (grepl('unexpected INCOMPLETE_STRING', message)) {
        # missing closing quotes
        'incomplete'
    } else {
        # all else
        'invalid'
    }
    
    content <- list(status = status)
    if (status == 'incomplete') {
        # we don't try to guess the indention level and just return zero indention
        # That's fine because R has braces... :-)
        # TODO: do some guessing?
        content <- c(content, indent = '')
    }
    
    send_response('is_complete_reply', request, 'shell', content)
},

complete = function(request) {
    # 5.0 protocol:
    code <- request$content$code
    cursor_pos <- request$content$cursor_pos
    
    # Find which line we're on and position within that line
    lines <- strsplit(code, '\n', fixed = TRUE)[[1]]
    chars_before_line <- 0L
    for (line in lines) {
        new_cursor_pos <- cursor_pos - nchar(line) - 1L # -1 for the newline
        if (new_cursor_pos < 0L) {
            break
        }
        cursor_pos <- new_cursor_pos
        chars_before_line <- chars_before_line + nchar(line) + 1L
    }
    
    utils:::.assignLinebuffer(line)
    utils:::.assignEnd(cursor_pos)
    utils:::.guessTokenFromLine()
    utils:::.completeToken()
        
    # .guessTokenFromLine, like most other functions here usually sets variables in .CompletionEnv.
    # When specifying update = FALSE, it instead returns a list(token = ..., start = ...)
    c.info <- c(
        list(comps = utils:::.retrieveCompletions()),
        utils:::.guessTokenFromLine(update = FALSE))
    
    # good coding style for completions
    comps <- gsub('=$', ' = ', c.info$comps)
    
    start_position <- chars_before_line + c.info$start
    send_response('complete_reply', request, 'shell', list(
        matches = as.list(comps),  # make single strings not explode into letters
        metadata = namedlist(),
        status = 'ok',
        cursor_start = start_position,
        cursor_end = start_position + nchar(c.info$token)))
},

history = function(request) {
    send_response('history_reply', request, 'shell', list(history = list()))
},

kernel_info = function(request) {
    rversion <- paste0(version$major, '.', version$minor)
    send_response('kernel_info_reply', request, 'shell', list(
        protocol_version       = '5.0',
        implementation         = 'IRkernel',
        implementation_version = as.character(packageVersion('IRkernel')),
        language_info = list(
            name = 'R',
            codemirror_mode = 'r',
            pygments_lexer = 'r',
            mimetype = 'text/x-r-source',
            file_extension = '.r',
            version = rversion),
        banner = version$version.string))
},

handle_control = function() {
    parts <- receive.multipart(sockets$control)
    msg <- wire_to_msg(parts)
    if (msg$header$msg_type == 'shutdown_request') {
        shutdown(msg)
    } else {
        print(paste('Unhandled control message, msg_type:', msg$header$msg_type))
    }
},

shutdown = function(request) {
    send_response('shutdown_reply', request, 'control', list(
        restart = request$content$restart))
    quit('no')
},

initialize = function(connection_file) {
    print("Initialize")
    connection_info <<- fromJSON(connection_file)
    print("Connection info")
    print(connection_info)
    
    url <- paste0(connection_info$transport, '://', connection_info$ip)
    url_with_port <- function(port_name) {
        paste0(url, ':', connection_info[[port_name]])
    }
    
    # ZMQ Socket setup
    zmqctx <<- init.context()
    sockets <<- list(
        hb      = init.socket(zmqctx, 'ZMQ_REP'),
        iopub   = init.socket(zmqctx, 'ZMQ_PUB'),
        control = init.socket(zmqctx, 'ZMQ_ROUTER'),
        stdin   = init.socket(zmqctx, 'ZMQ_ROUTER'),
        shell   = init.socket(zmqctx, 'ZMQ_ROUTER'))
    
    print("binding sockets")
    bind.socket(sockets$hb,      url_with_port('hb_port'))
    bind.socket(sockets$iopub,   url_with_port('iopub_port'))
    bind.socket(sockets$control, url_with_port('control_port'))
    bind.socket(sockets$stdin,   url_with_port('stdin_port'))
    bind.socket(sockets$shell,   url_with_port('shell_port'))
    print("Sockets bound")
    
    executor <<- Executor$new(send_response = .self$send_response)
},

run = function() {
    while (TRUE) {
        events <- poll.socket(
            list(sockets$hb, sockets$shell, sockets$control),
            list('read', 'read', 'read'), timeout = -1L)
        
        if (events[[1]]$read) {
            # heartbeat
            hb_reply()
        }
        
        if (events[[2]]$read) {
            # Shell socket
            handle_shell()
        }
        
        if (events[[3]]$read) {  # Control socket
            handle_control()
        }
    }
})
)

#'Initialise and run the kernel
#'
#'@param connection_file The path to the Jupyter connection file, written by the frontend
#'@export 
main <- function(connection_file = '') {
    print("Main()")
    if (connection_file == '') {
        # On Windows, passing the connection file in as a string literal fails,
        # because the \U in C:\Users looks like a unicode escape. So, we have to
        # pass it as a separate command line argument.
        connection_file = commandArgs(TRUE)[[1]]
    }
    print(connection_file)
    kernel <- Kernel$new(connection_file = connection_file)
    kernel$run()
}

#'Install the kernelspec to tell Jupyter (or IPython ≥ 3) about IRkernel.
#'
#'Will use jupyter and its config directory if available, but fall back to ipython if not.
#'
#'@param user Install into user directory (~/.jupyter or ~/.ipython) or globally?
#'@export
installspec <- function(user = TRUE) {
    found_binary <- FALSE
    for (binary in c('jupyter', 'ipython', 'ipython3', 'ipython2')) {
        version <- tryCatch(system2(binary, '--version', TRUE, FALSE), error = function(e) '0.0.0')
        if (compareVersion(version, '3.0.0') >= 0) {
            found_binary <- TRUE
            break
        }
    }
    
    if (!found_binary)
        stop('Jupyter or IPython 3.0 has to be installed but could neither run “jupyter” nor “ipython”, “ipython2” or “ipython3”.
             (Note that “ipython2” is just IPython for Python 2, but still may be IPython 3.0)')
    
    # make a kernelspec with the current interpreter's absolute path
    srcdir <- system.file('kernelspec', package = 'IRkernel')
    tmp_name <- tempfile()
    dir.create(tmp_name)
    file.copy(srcdir, tmp_name, recursive = TRUE)
    spec_path <- file.path(tmp_name, 'kernelspec', 'kernel.json')
    spec <- fromJSON(spec_path)
    spec$argv[[1]] <- file.path(R.home('bin'), 'R')
    write(toJSON(spec, pretty = TRUE, auto_unbox = TRUE), file = spec_path)

    user_flag <- if (user) '--user' else character(0)
    args <- c('kernelspec', 'install', '--replace', '--name', 'ir', user_flag, file.path(tmp_name, 'kernelspec'))
    system2(binary, args, wait = TRUE)

    unlink(tmp_name, recursive = TRUE)
}
