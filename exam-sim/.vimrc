" Exam-sim vimrc — optimised for K8s YAML editing under exam conditions.
" Install: cp exam-sim/.vimrc ~/.vimrc  (or run exam-sim/setup.sh)

" ── Core ────────────────────────────────────────────────────────────────────
set nocompatible
syntax on
filetype plugin indent on

" ── Indentation — 2 spaces, always (YAML requires consistency) ───────────────
set tabstop=2
set softtabstop=2
set shiftwidth=2
set expandtab          " spaces not tabs — YAML hates tabs
set autoindent
set smartindent

" ── Line numbers and display ──────────────────────────────────────────────────
set number
set relativenumber     " relative numbers make gg/G/dd jumps faster
set ruler
set showcmd
set showmode
set cursorline

" ── Search ────────────────────────────────────────────────────────────────────
set incsearch
set hlsearch
set ignorecase
set smartcase
nnoremap <Esc><Esc> :nohlsearch<CR>

" ── Editing quality of life ───────────────────────────────────────────────────
set backspace=indent,eol,start
set scrolloff=5        " keep 5 lines visible above/below cursor
set wrap
set linebreak

" ── Paste mode toggle — prevents auto-indent mangling pasted YAML ─────────────
set pastetoggle=<F2>

" ── Undo persistence ──────────────────────────────────────────────────────────
set undolevels=200

" ── Faster buffer navigation ──────────────────────────────────────────────────
nnoremap <C-n> :bnext<CR>
nnoremap <C-p> :bprev<CR>

" ── Quick save / quit ─────────────────────────────────────────────────────────
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>
nnoremap <leader>x :x<CR>

" ── YAML-specific helpers ─────────────────────────────────────────────────────
" \y → set 2-space YAML indent for current buffer
nnoremap <leader>y :set ts=2 sts=2 sw=2 et<CR>

" ── kubectl shorthand — run kubectl on the current file without leaving vim ───
" \k → kubectl apply -f %  (dry-run first via \d)
nnoremap <leader>k :!kubectl apply -f %<CR>
nnoremap <leader>d :!kubectl apply -f % --dry-run=client<CR>

" ── Colour scheme — close to the exam terminal ────────────────────────────────
set background=dark
" Use built-in 'desert' if nothing else is available (always present)
silent! colorscheme desert

" ── Status line ───────────────────────────────────────────────────────────────
set laststatus=2
set statusline=%f\ %m%r\ %y\ [%l/%L\ col\ %c]\ %p%%

" ── Wildmenu (tab completion in command mode) ─────────────────────────────────
set wildmenu
set wildmode=list:longest,full
