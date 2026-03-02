-- Options
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
vim.o.number = true
vim.o.relativenumber = true
vim.o.mouse = 'a'
vim.o.showmode = false
vim.o.breakindent = true
vim.o.undofile = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.signcolumn = 'yes'
vim.o.updatetime = 250
vim.o.timeoutlen = 300
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.list = true
vim.opt.listchars = { tab = '  ', trail = '·', nbsp = '␣' }
vim.o.inccommand = 'split'
vim.o.cursorline = true
vim.o.scrolloff = 10
vim.o.tabstop = 4
vim.o.shiftwidth = 4
vim.o.expandtab = true
vim.o.termguicolors = true

-- Colorscheme
require('tokyonight').setup {
  style = 'night',
  transparent = false,
  terminal_colors = true,
  styles = {
    comments = { italic = true },
    keywords = { italic = true },
  },
  on_highlights = function(hl, c)
    hl.CursorLineNr = { fg = c.orange, bold = true }
  end,
}
vim.cmd.colorscheme 'tokyonight-night'

-- Keymaps
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Diagnostics list' })
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Focus left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Focus right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Focus lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Focus upper window' })

-- Highlight on yank
vim.api.nvim_create_autocmd('TextYankPost', {
  group = vim.api.nvim_create_augroup('highlight-yank', { clear = true }),
  callback = function() vim.hl.on_yank() end,
})

-- Auto-reload files changed by Claude Code
vim.o.autoread = true
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  group = vim.api.nvim_create_augroup('auto-reload', { clear = true }),
  command = 'checktime',
})

-- Plugin setup (lazy-loaded via packadd)

-- Which-key
vim.cmd.packadd('which-key.nvim')
require('which-key').setup()
require('which-key').add {
  { '<leader>s', group = 'Search' },
  { '<leader>g', group = 'Git' },
  { '<leader>c', group = 'Claude' },
}

-- Telescope
vim.cmd.packadd('telescope-fzf-native.nvim')
vim.cmd.packadd('telescope.nvim')
local telescope = require('telescope')
telescope.setup {
  defaults = {
    layout_strategy = 'horizontal',
    layout_config = { prompt_position = 'top' },
    sorting_strategy = 'ascending',
  },
}
pcall(telescope.load_extension, 'fzf')
local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = 'Search files' })
vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = 'Search by grep' })
vim.keymap.set('n', '<leader>sb', builtin.buffers, { desc = 'Search buffers' })
vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = 'Search help' })
vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = 'Search diagnostics' })
vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = 'Search resume' })
vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = 'Search recent files' })
vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = 'Find buffer' })
vim.keymap.set('n', '<leader>/', builtin.current_buffer_fuzzy_find, { desc = 'Search in buffer' })

-- Gitsigns
vim.cmd.packadd('gitsigns.nvim')
require('gitsigns').setup {
  signs = {
    add = { text = '+' },
    change = { text = '~' },
    delete = { text = '_' },
    topdelete = { text = '‾' },
    changedelete = { text = '~' },
  },
  on_attach = function(bufnr)
    local gs = require('gitsigns')
    local map = function(mode, l, r, opts)
      opts = opts or {}
      opts.buffer = bufnr
      vim.keymap.set(mode, l, r, opts)
    end
    map('n', ']h', gs.next_hunk, { desc = 'Next hunk' })
    map('n', '[h', gs.prev_hunk, { desc = 'Previous hunk' })
    map('n', '<leader>gs', gs.stage_hunk, { desc = 'Stage hunk' })
    map('n', '<leader>gr', gs.reset_hunk, { desc = 'Reset hunk' })
    map('n', '<leader>gp', gs.preview_hunk, { desc = 'Preview hunk' })
    map('n', '<leader>gb', gs.blame_line, { desc = 'Blame line' })
    map('n', '<leader>gd', gs.diffthis, { desc = 'Diff this' })
  end,
}

-- Oil (file explorer as buffer)
vim.cmd.packadd('oil.nvim')
require('oil').setup {
  view_options = { show_hidden = true },
}
vim.keymap.set('n', '-', '<cmd>Oil<CR>', { desc = 'Open file explorer' })

-- Lualine
vim.cmd.packadd('lualine.nvim')
require('lualine').setup {
  options = {
    theme = 'tokyonight',
    component_separators = '|',
    section_separators = '',
  },
}

-- Treesitter (grammars provided by nix, neovim 0.11+ built-in API)
vim.cmd.packadd('nvim-treesitter')
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('treesitter-start', { clear = true }),
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)
  end,
})

-- Completion (blink.cmp)
vim.cmd.packadd('blink.cmp')
require('blink.cmp').setup {
  keymap = { preset = 'default' },
  appearance = { nerd_font_variant = 'mono' },
  sources = { default = { 'lsp', 'path', 'buffer' } },
  signature = { enabled = true },
}

-- Conform (formatting)
vim.cmd.packadd('conform.nvim')
require('conform').setup {
  formatters_by_ft = {
    go = { 'gofmt' },
    nix = { 'nixfmt' },
    python = { 'ruff_format' },
    terraform = { 'terraform_fmt' },
    yaml = { 'yamlfmt' },
  },
  format_on_save = {
    timeout_ms = 500,
    lsp_format = 'fallback',
  },
}
vim.keymap.set('n', '<leader>f', function()
  require('conform').format { async = true, lsp_format = 'fallback' }
end, { desc = 'Format buffer' })

-- LSP
vim.cmd.packadd('nvim-lspconfig')

local on_attach = function(_, bufnr)
  local map = function(keys, func, desc)
    vim.keymap.set('n', keys, func, { buffer = bufnr, desc = desc })
  end
  map('gd', builtin.lsp_definitions, 'Go to definition')
  map('gr', builtin.lsp_references, 'Go to references')
  map('gI', builtin.lsp_implementations, 'Go to implementation')
  map('<leader>D', builtin.lsp_type_definitions, 'Type definition')
  map('<leader>ds', builtin.lsp_document_symbols, 'Document symbols')
  map('<leader>ws', builtin.lsp_dynamic_workspace_symbols, 'Workspace symbols')
  map('<leader>rn', vim.lsp.buf.rename, 'Rename')
  map('<leader>ca', vim.lsp.buf.code_action, 'Code action')
  map('K', vim.lsp.buf.hover, 'Hover documentation')
  map('gD', vim.lsp.buf.declaration, 'Go to declaration')
end

local servers = {
  gopls = {},
  nil_ls = {},
  pyright = {},
  ts_ls = {},
  yamlls = {},
  terraformls = {},
}

for server, config in pairs(servers) do
  config.on_attach = on_attach
  vim.lsp.config(server, config)
  vim.lsp.enable(server)
end

-- Claude Code integration
if nixCats('claude') then
  vim.cmd.packadd('snacks.nvim')
  vim.cmd.packadd('claudecode.nvim')
  require('claudecode').setup()
  vim.keymap.set('n', '<leader>cc', '<cmd>ClaudeCodeToggle<CR>', { desc = 'Toggle Claude Code' })
  vim.keymap.set('v', '<leader>cs', '<cmd>ClaudeCodeSend<CR>', { desc = 'Send to Claude' })
  vim.keymap.set('n', '<leader>co', '<cmd>ClaudeCodeOpen<CR>', { desc = 'Open Claude Code' })
end
