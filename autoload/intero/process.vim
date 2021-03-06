"""""""""""
" Process:
"
" This file contains functions for working with the Intero process. This
" includes ensuring that Intero is installed, starting/killing the
" process, and hiding/showing the REPL.
"""""""""""

" Lines of output consistuting of a command and the response to it
let s:current_response = []

" The current (incomplete) line
let s:current_line = ''

" Whether Intero has finished starting yet
let g:intero_started = 0

" Whether Intero has done its initialization yet
let s:intero_initialized = 0

" If true, echo the next response. Reset after each response.
let g:intero_echo_next = 0

" Queue of functions to run when a response is received. For a given response,
" only the first will be run, after which it will be dropped from the queue.
let s:response_handlers = []

" The name of the buffer that displays Intero compilation progress.
let s:compile_term_name = 'Intero_compile'

function! intero#process#initialize() abort
    " This function initializes Intero.
    " It sets any global states we need, builds 'intero' if needed, and emits
    " any appropriate warnings to the user.

    " We only need to initialize once
    if s:intero_initialized
        return
    endif

    if(!exists('g:intero_built'))
        " If `stack` exits with a non-0 exit code, that means it failed to find the executable.
        if (!executable('stack'))
            echom 'Stack is required for Intero. Aborting.'
            return
        endif

        " We haven't set the stack-root yet, so we shouldn't be able to find this yet.
        if (executable('intero'))
            echom 'Intero is installed in your PATH, which may cause problems when using different resolvers.'
            echom 'This usually happens if you run `stack install intero` instead of `stack build intero`.'
            echom 'Aborting.'
            return
        endif

        if g:intero_use_neomake && !exists(':Neomake')
            echom 'Neomake not detected. Flychecking will be disabled.'
        endif

        " Load Python code
        py import sys
        call pyeval('sys.path.append("' . g:intero_plugin_root . '")')
        py import intero

        " Find stack.yaml
        if (!exists('g:intero_stack_yaml'))
            " Change dir temporarily and see if stack can find a config
            silent! lcd %:p:h
            let g:intero_stack_yaml = systemlist('stack path --config-location')[-1]
            silent! lcd -
        endif

        " Ensure that intero is compiled
        " TODO: Verify that we have a version of intero that the plugin can work with.
        let l:version = system('stack ' . intero#util#stack_opts() . ' exec --verbosity silent -- intero --version')
        if v:shell_error
            let g:intero_built = 0
            echom 'Intero not installed.'
            let l:opts = { 'on_exit': function('s:build_complete') }
            call s:start_compile(10, l:opts)
        else
            let g:intero_built = 1
        endif
    endif

    let s:intero_initialized = 1
endfunction

function! intero#process#start() abort
    " This is the entry point. It ensures that Intero is initialized, then
    " starts an intero terminal buffer. Initially only occupies a small area.
    " Returns the intero buffer id.

    call intero#process#initialize()

    if(!exists('g:intero_built') || g:intero_built == 0)
        echom 'Intero is still compiling'
        return -1
    endif

    if !exists('g:intero_buffer_id')
        let g:intero_buffer_id = s:start_buffer(10)
    endif

    augroup close_intero
        autocmd!
        autocmd VimLeavePre * call intero#process#kill()
        autocmd VimLeave * call intero#maker#cleanup()
    augroup END

    return g:intero_buffer_id
endfunction

function! intero#process#kill() abort
    " Kills the intero buffer, if it exists.
    if exists('g:intero_buffer_id')
        exe 'bd! ' . g:intero_buffer_id
        unlet g:intero_buffer_id
        " Deleting a terminal buffer implicitly stops the job
        unlet g:intero_job_id
    else
        echo 'No Intero process loaded.'
    endif
endfunction

function! intero#process#hide() abort
    " Hides the current buffer without killing the process.
    silent! call s:hide_buffer()
endfunction

function! intero#process#open() abort
    " Opens the Intero REPL. If the REPL isn't currently running, then this
    " creates it. If the REPL is already running, this is a noop. Returns the
    " window ID.
    call intero#process#initialize()

    let l:intero_win = intero#util#get_intero_window()
    if l:intero_win != -1
        return l:intero_win
    elseif exists('g:intero_buffer_id')
        let l:current_window = winnr()
        silent! call s:open_window(10)
        exe 'silent! buffer ' . g:intero_buffer_id
        normal! G
        exe 'silent! ' . l:current_window . 'wincmd w'
    else
        let l:rc = intero#process#start()
        if l:rc < 0
            return
        endif
        return intero#process#open()
    endif
endfunction

function! intero#process#add_handler(func) abort
    " Adds an event handler to the queue
    let s:response_handlers = s:response_handlers + [a:func]
endfunction

function! intero#process#restart() abort
    call intero#process#kill()
    call intero#process#start()
endfunction

function! intero#process#restart_with_targets(...) abort
    call intero#util#set_load_targets(a:000)
    call intero#process#restart()
endfunction

""""""""""
" Private:
""""""""""

function! s:start_compile(height, opts) abort
    " Starts an Intero compiling in a split below the current buffer.
    " Returns the ID of the buffer.
    exe 'below ' . a:height . ' split'

    enew!
    call termopen('stack ' . intero#util#stack_opts() . ' build intero', a:opts)
    execute 'file ' . s:compile_term_name

    set bufhidden=hide
    set noswapfile
    set hidden
    let l:buffer_id = bufnr('%')
    let g:intero_job_id = b:terminal_job_id
    call feedkeys("\<ESC>")
    wincmd w
    return l:buffer_id
endfunction

function! s:start_buffer(height) abort
    " Starts an Intero REPL in a split below the current buffer. Returns the
    " ID of the buffer.
    exe 'below ' . a:height . ' split'

    enew
    call termopen('stack ' 
        \ . intero#util#stack_opts() 
        \ . ' ghci --with-ghc intero '
        \ . intero#util#stack_build_opts(), {
                \ 'on_stdout': function('s:on_stdout'),
                \ 'cwd': pyeval('intero.stack_dirname()')
                \ })

    file Intero
    set bufhidden=hide
    set noswapfile
    set hidden
    let l:buffer_id = bufnr('%')
    let g:intero_job_id = b:terminal_job_id
    quit
    call feedkeys("\<ESC>")
    return l:buffer_id
endfunction

function! s:on_stdout(jobid, lines, event) abort
    if !exists('g:intero_prompt_regex')
        let g:intero_prompt_regex = '[^-]> '
    endif

    for l:line_seg in a:lines
        let s:current_line = s:current_line . l:line_seg

        " If we've found a newline, flush the line buffer
        if s:current_line =~# '\r$'
            " Remove trailing newline, control chars
            let s:current_line = substitute(s:current_line, '\r$', '', '')
            let s:current_line = pyeval('intero.strip_control_chars()')

            " Flush line buffer
            let s:current_response = s:current_response + [s:current_line]
            let s:current_line = ''
        endif

        " If the current line is a prompt, we just completed a response
        if s:current_line =~ (g:intero_prompt_regex . '$')
            if len(s:current_response) > 0
                " Separate the input command from the response
                let l:cmd = substitute(s:current_response[0], '.*' . g:intero_prompt_regex, '', '')
                call s:new_response(l:cmd, s:current_response[1:])
            endif

            let s:current_response = []
        endif

    endfor
endfunction

function! s:new_response(cmd, response) abort
    let l:initial_compile = 0

    " This means that Intero is now available to run commands
    " TODO: ignore commands until this is set
    if !g:intero_started
        echom 'Intero ready'
        let g:intero_started = 1
        let l:initial_compile = 1
    endif

    " For debugging
    let g:intero_response = a:response

    " These handlers are used for all events
    if g:intero_echo_next
        echo join(a:response, "\n")
        let g:intero_echo_next = 0
    endif

    if(l:initial_compile || a:cmd =~# ':reload')
        " Trigger Neomake's parsing of the compilation errors
        call intero#maker#write_update(a:response)
    endif

    " If a handler has been registered, pop it and run it
    if len(s:response_handlers) > 0
        call s:response_handlers[0](a:response)
        let s:response_handlers = s:response_handlers[1:]
    endif
endfunction

function! s:open_window(height) abort
    " Opens a window of a:height and moves it to the very bottom.
    exe 'below ' . a:height . ' split'
    normal! <C-w>J
endfunction

function! s:hide_buffer() abort
    " This closes the Intero REPL buffer without killing the process.
    if !s:intero_initialized
        " Intero was never started.
        return
    endif

    let l:window_number = intero#util#get_intero_window()
    if l:window_number > 0
        exec 'silent! ' . l:window_number . 'wincmd c'
    endif
endfunction

function! s:build_complete(job_id, data, event) abort
    if(a:event ==# 'exit')
        if(a:data == 0)
            let g:intero_built = 1
            echomsg 'Intero compiled successfully.'
            call intero#process#start()
            let l:compile_term = bufwinnr(s:compile_term_name)
            if l:compile_term > 0
                exec 'silent! ' . l:compile_term . 'wincmd q'
            endif
        else
            echom 'Intero failed to compile.'
        endif
    endif
endfunction
