" Plugin section managed by Nix, do not edit
" call plug#begin('~/.vim/plugged') 
"     Plug 'morhetz/gruvbox'
"     Plug 'sheerun/vim-polyglot'
"     Plug 'vim-airline/vim-airline-themes'
"     Plug 'vim-airline/vim-airline' 
"     Plug 'wakatime/vim-wakatime' 
"     Plug 'tpope/vim-fugitive'
"     Plug 'airblade/vim-gitgutter'
"     Plug 'tpope/vim-commentary'     
"     Plug 'preservim/nerdtree'
"     Plug 'neoclide/coc.nvim', {'branch': 'release'}
" call plug#end()

" set laststatus=2
set ttimeout ttimeoutlen=50
if !has('gui_running')
  set t_Co=256
endif
set noshowmode

" airline_theme
" let g:airline_theme='powerline'
let g:show_error = 0
let g:modification_color = 0
let g:airline_powerline_fonts = 1
let g:airline#extensions#tabline#enabled = 1

set clipboard=unnamedplus

"tab manager
nmap <S-left> :tabprev<CR>
nmap <S-right> :tabnext<CR>
nmap <S-M> :tab new<CR>


"disable highlight
:nohlsearch
nnoremap <C-e> :nohlsearch<CR>

" mouse active
set mouse=a

" split behaviour
nnoremap <C-J> <C-W><C-J>
nnoremap <C-K> <C-W><C-K>
nnoremap <C-L> <C-W><C-L>
nnoremap <C-H> <C-W><C-H>
set splitright
set splitbelow

" brackets pairs
nnoremap <C-b> :RainbowToggle<CR>
inoremap /* /**/<left><left>
inoremap " ""<left>
inoremap ' ''<left>
inoremap ( ()<left>
inoremap [ []<left>
inoremap { {}<left>
inoremap {<CR> {<CR>}<ESC>O
inoremap {;<CR> {<CR>};<ESC>O

" line and column behaviour
:set cursorline
set colorcolumn=80
highlight Normal ctermfg=black ctermbg=lightgrey

" color schema
if has("termguicolors")
  set termguicolors
endif
syntax on
" set background=dark
" colorscheme gruvbox
:hi Comment None

" duplicate line
nnoremap <C-d> yyp:-1<CR>


" function to rename the variable under the cursor
nnoremap <C-q> :call Rnvar()<CR>
function! Rnvar()
  let word_to_replace = expand("<cword>")
  let replacement = input("new name: ")
  execute '%s/\(\W\)' . word_to_replace . '\(\W\)/\1' . replacement . '\2/gc'
endfunction

" nerd tree
nnoremap <C-right> :NERDTreeToggle<CR>
nnoremap <C-left> :NERDTree<CR>
let NERDTreeQuitOnOpen=1
"Start NERDTree when Vim starts with a directory argument.
autocmd StdinReadPre * let s:std_in=1
autocmd VimEnter * if argc() == 1 && isdirectory(argv()[0]) && !exists('s:std_in') |
    \ execute 'NERDTree' argv()[0] | wincmd p | enew | execute 'cd '.argv()[0] | endif
" Exit Vim if NERDTree is the only window remaining in the only tab.
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" other command
set encoding=utf-8
set nobackup
set nowritebackup
set updatetime=300
set signcolumn=yes
set number
set linebreak
set showbreak=+++
set textwidth=80
set showmatch
set hlsearch
set smartcase
set ignorecase
set incsearch
set autoindent
set cindent
set expandtab
set shiftwidth=4
set smartindent
set smarttab
set softtabstop=4
set ruler
set undolevels=1000
set backspace=indent,eol,start
set nocompatible
set tabstop=4
set showmatch
set comments=sl:/*,mb:\ *,elx:\ */


"--------------------------------------COC------------------------------------"

function! CheckBackspace() abort
  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction

inoremap <silent><expr> <TAB>
      \ coc#pum#visible() ? coc#pum#confirm() :
      \ CheckBackspace() ? "\<Tab>" :
      \ coc#refresh()

inoremap <silent><expr> <CR> coc#pum#visible() ? coc#pum#confirm()
                              \: "\<C-g>u\<CR>\<c-r>=coc#on_enter()\<CR>"

" Add `:Format` command to format current buffer
command! -nargs=0 Format :call CocActionAsync('format')

" Add `:Fold` command to fold current buffer
command! -nargs=? Fold :call     CocAction('fold', <f-args>)

" Add `:OR` command for organize imports of the current buffer
command! -nargs=0 OR   :call     CocActionAsync('runCommand', 'editor.action.organizeImport')

" Add (Neo)Vim's native statusline support
" NOTE: Please see `:h coc-status` for integrations with external plugins that
" provide custom statusline: lightline.vim, vim-airline
set statusline^=%{coc#status()}%{get(b:,'coc_current_function','')}