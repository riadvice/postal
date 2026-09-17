# Structured "add filter" builder for the message search box.
#
# The wire format submitted to the server is unchanged (the same
# `key: value`/`key: "quoted value"` query string that QueryString parses),
# so this file only has to do two things: turn the filter rows into that
# string before submit, and turn the string (already parsed server-side into
# `data-initial-filters`) back into rows when a page loads.

FIELDS =
  to:      label: 'To',         kind: 'text',   ops: ['equals', 'contains', 'starts_with']
  from:    label: 'From',       kind: 'text',   ops: ['equals', 'contains', 'starts_with']
  subject: label: 'Subject',    kind: 'text',   ops: ['equals', 'contains', 'starts_with']
  status:  label: 'Status',     kind: 'remote', ops: ['equals'], remoteField: 'status'
  tag:     label: 'Tag',        kind: 'remote', ops: ['equals'], remoteField: 'tag'
  spam:    label: 'Spam',       kind: 'boolean', ops: ['equals']
  held:    label: 'Held',       kind: 'boolean', ops: ['equals']
  threat:  label: 'Threat',     kind: 'boolean', ops: ['equals']
  before:  label: 'Before',     kind: 'datetime', ops: ['equals']
  after:   label: 'After',      kind: 'datetime', ops: ['equals']
  id:      label: 'ID',         kind: 'text',   ops: ['equals']
  msgid:   label: 'Message-ID', kind: 'text',   ops: ['equals']
  token:   label: 'Token',      kind: 'text',   ops: ['equals']

FIELD_ORDER = ['to', 'from', 'subject', 'status', 'tag', 'spam', 'held', 'threat', 'before', 'after', 'id', 'msgid', 'token']

OPERATOR_LABELS =
  equals: 'is'
  contains: 'contains'
  starts_with: 'starts with'

remoteValuesCache = {}

debounce = (fn, delay) ->
  timer = null
  (args...) ->
    context = this
    clearTimeout(timer)
    timer = setTimeout((-> fn.apply(context, args)), delay)

getRoot = ($el) -> $el.closest('.messageSearch')

getForm = ($root) -> $('.js-message-filter-form', $root)

getFilterList = ($root) -> $('.js-message-filters', $root)

# --- value <-> operator/display splitting (mirrors MessagesController#text_match_value) ---

splitValue = (raw) ->
  value = String(raw ? '')
  if value.length > 1 and value.charAt(0) is '*' and value.charAt(value.length - 1) is '*'
    operator: 'contains', value: value.slice(1, -1)
  else if value.length > 1 and value.charAt(value.length - 1) is '*'
    operator: 'starts_with', value: value.slice(0, -1)
  else
    operator: 'equals', value: value

joinValue = (operator, value) ->
  switch operator
    when 'contains' then "*#{value}*"
    when 'starts_with' then "#{value}*"
    else value

tokenFor = (field, operator, rawValue) ->
  value = String(rawValue ? '').trim()
  return null if value is ''
  value = joinValue(operator, value)
  value = value.replace(/"/g, '')
  if value.indexOf(' ') > -1
    "#{field}: \"#{value}\""
  else
    "#{field}: #{value}"

# --- row rendering ---

fieldOptionsHtml = (selected) ->
  html = ''
  for field in FIELD_ORDER
    sel = if field is selected then ' selected' else ''
    html += "<option value=\"#{field}\"#{sel}>#{FIELDS[field].label}</option>"
  html

operatorOptionsHtml = (field, selected) ->
  ops = FIELDS[field]?.ops ? ['equals']
  html = ''
  for op in ops
    sel = if op is selected then ' selected' else ''
    html += "<option value=\"#{op}\"#{sel}>#{OPERATOR_LABELS[op]}</option>"
  html

buildValueControlHtml = (field, value) ->
  meta = FIELDS[field]
  if meta?.kind is 'boolean'
    selected = if String(value).toLowerCase() in ['yes', 'y', 'true', '1'] then 'yes' else 'no'
    "<select class=\"messageFilters__value js-filter-value\">
      <option value=\"yes\"#{if selected is 'yes' then ' selected' else ''}>Yes</option>
      <option value=\"no\"#{if selected is 'no' then ' selected' else ''}>No</option>
    </select>"
  else if meta?.kind is 'datetime'
    "<input type=\"text\" class=\"messageFilters__value js-filter-value\" placeholder=\"yyyy-mm-dd hh:mm\" value=\"#{$('<div>').text(value).html()}\" autocomplete=\"off\">"
  else
    "<span class=\"messageFilters__valueWrap\">
      <input type=\"text\" class=\"messageFilters__value js-filter-value\" value=\"#{$('<div>').text(value).html()}\" autocomplete=\"off\">
      <ul class=\"messageFilters__suggestions js-filter-suggestions is-hidden\"></ul>
    </span>"

rowHtml = (field, operator, value) ->
  field = field ? 'to'
  operator = operator ? 'equals'
  value = value ? ''
  "<div class=\"messageFilters__row js-filter-row\">
    <select class=\"messageFilters__field js-filter-field\">#{fieldOptionsHtml(field)}</select>
    <select class=\"messageFilters__operator js-filter-operator\">#{operatorOptionsHtml(field, operator)}</select>
    #{buildValueControlHtml(field, value)}
    <button type=\"button\" class=\"messageFilters__remove js-filter-remove\" aria-label=\"Remove filter\">&times;</button>
  </div>"

addRow = ($root, field, operator, value) ->
  $row = $(rowHtml(field, operator, value))
  getFilterList($root).append($row)
  $row

# --- serialization: rows -> query string ---

syncQuery = ($root) ->
  return if $root.hasClass('is-advanced')

  tokens = []
  $('.js-filter-row', $root).each ->
    $row = $(this)
    field = $('.js-filter-field', $row).val()
    operator = $('.js-filter-operator', $row).val()
    value = $('.js-filter-value', $row).val()
    token = tokenFor(field, operator, value)
    tokens.push(token) if token
  $('.js-message-filter-query', $root).val(tokens.join(' '))
  updateFilterCount($root)

syncQueryFromAdvanced = ($root) ->
  return unless $root.hasClass('is-advanced')

  $('.js-message-filter-query', $root).val($('.js-advanced-input', $root).val())
  updateFilterCount($root)

# --- active filter count badge ---

updateFilterCount = ($root) ->
  $badge = $('.js-filter-count', $root)
  return unless $badge.length

  query = $('.js-message-filter-query', $root).val() or ''
  count = (query.match(/[a-z]+:\s*\S/gi) or []).length

  if count > 0
    $badge.text("#{count} filter#{if count is 1 then '' else 's'} active").removeClass('is-hidden')
  else
    $badge.addClass('is-hidden').empty()

# --- autocomplete ---

fetchRemoteValues = ($root, field, callback) ->
  cacheKey = "#{$root.data('server-id')}:#{field}"
  if remoteValuesCache[cacheKey]
    callback(remoteValuesCache[cacheKey])
    return

  url = $root.data('filter-values-url')
  return unless url

  $.getJSON(url, { field: field }).done((data) ->
    values = data?.values ? []
    remoteValuesCache[cacheKey] = values
    callback(values)
  ).fail(-> callback([]))

showSuggestions = ($input, values) ->
  $list = $input.siblings('.js-filter-suggestions')
  return unless $list.length

  query = $input.val().toLowerCase()
  matches = (v for v in values when query is '' or String(v).toLowerCase().indexOf(query) > -1)

  if matches.length is 0
    $list.addClass('is-hidden').empty()
    return

  $list.empty()
  for value in matches
    $list.append($('<li class="messageFilters__suggestion js-filter-suggestion">').text(value))
  $list.removeClass('is-hidden')

hideSuggestions = ($input) ->
  $input.siblings('.js-filter-suggestions').addClass('is-hidden').empty()

updateSuggestionsForInput = ($input) ->
  $row = $input.closest('.js-filter-row')
  field = $('.js-filter-field', $row).val()
  meta = FIELDS[field]
  return unless meta?.kind is 'remote'

  fetchRemoteValues(getRoot($input), meta.remoteField, (values) -> showSuggestions($input, values))

debouncedUpdateSuggestions = debounce(updateSuggestionsForInput, 200)

# --- bootstrapping rows from server-parsed filters ---

buildInitialRows = ($root) ->
  raw = $root.attr('data-initial-filters')
  filters = {}
  if raw
    try
      filters = JSON.parse(raw) ? {}
    catch e
      filters = {}

  getFilterList($root).empty()

  any = false
  for field in FIELD_ORDER
    continue unless filters.hasOwnProperty(field)
    values = filters[field]
    values = [values] unless $.isArray(values)
    for value in values
      parts = splitValue(value)
      addRow($root, field, parts.operator, parts.value)
      any = true

  addRow($root, 'to', 'equals', '') unless any
  updateFilterCount($root)

# --- saved searches (localStorage only, per server) ---

storageKey = ($root) -> "postal.savedSearches.#{$root.data('server-id')}"

loadSavedSearches = ($root) ->
  try
    JSON.parse(window.localStorage.getItem(storageKey($root)) or '[]') or []
  catch e
    []

storeSavedSearches = ($root, list) ->
  try
    window.localStorage.setItem(storageKey($root), JSON.stringify(list))
  catch e
    null

renderSavedSearchOptions = ($root) ->
  $select = $('.js-saved-search-select', $root)
  return unless $select.length

  list = loadSavedSearches($root)
  $select.find('option').slice(1).remove()
  for item in list
    $select.append($('<option>').val(item.query).text(item.name))
  $select.val('')

currentQueryValue = ($root) ->
  if $root.hasClass('is-advanced')
    $('.js-advanced-input', $root).val()
  else
    $('.js-message-filter-query', $root).val()

# --- init ---

initFilterBuilder = ->
  $('.messageSearch').each ->
    $root = $(this)
    buildInitialRows($root)
    renderSavedSearchOptions($root)

$ ->
  $(document)
    .on('turbolinks:load', initFilterBuilder)
    .on('ajax:complete', initFilterBuilder)

    .on('click', '.js-message-filter-add', (event) ->
      event.preventDefault()
      $root = getRoot($(this))
      addRow($root, 'to', 'equals', '')
    )

    .on('click', '.js-message-filter-clear', (event) ->
      event.preventDefault()
      $root = getRoot($(this))
      $('.js-message-filter-query, .js-advanced-input', $root).val('')
      getFilterList($root).empty()
      addRow($root, 'to', 'equals', '')
      updateFilterCount($root)
      getForm($root).trigger('submit')
    )

    .on('click', '.js-filter-remove', (event) ->
      event.preventDefault()
      $root = getRoot($(this))
      $row = $(this).closest('.js-filter-row')
      $list = getFilterList($root)
      $row.remove()
      addRow($root, 'to', 'equals', '') if $('.js-filter-row', $list).length is 0
      syncQuery($root)
    )

    .on('change', '.js-filter-field', (event) ->
      $row = $(this).closest('.js-filter-row')
      $root = getRoot($(this))
      field = $(this).val()
      $row.find('.js-filter-operator').replaceWith("<select class=\"messageFilters__operator js-filter-operator\">#{operatorOptionsHtml(field, 'equals')}</select>")
      $row.find('.messageFilters__value, .messageFilters__valueWrap').remove()
      $row.find('.js-filter-operator').after(buildValueControlHtml(field, ''))
      syncQuery($root)
    )

    .on('change', '.js-filter-operator, .js-filter-value', (event) ->
      syncQuery(getRoot($(this)))
    )

    .on('input', '.js-filter-value', (event) ->
      $input = $(this)
      syncQuery(getRoot($input))
      debouncedUpdateSuggestions($input)
    )

    .on('focus', '.js-filter-value', (event) ->
      updateSuggestionsForInput($(this))
    )

    .on('blur', '.js-filter-value', (event) ->
      $input = $(this)
      setTimeout((-> hideSuggestions($input)), 150)
    )

    .on('click', '.js-filter-suggestion', (event) ->
      $suggestion = $(this)
      $input = $suggestion.closest('.messageFilters__valueWrap').find('.js-filter-value')
      $input.val($suggestion.text())
      hideSuggestions($input)
      syncQuery(getRoot($input))
    )

    .on('input', '.js-advanced-input', (event) ->
      syncQueryFromAdvanced(getRoot($(this)))
    )

    .on('click', '.js-toggle-advanced', (event) ->
      event.preventDefault()
      $root = getRoot($(this))
      $root.toggleClass('is-advanced')
      $('.js-advanced-box', $root).toggleClass('is-hidden')
      $('.js-message-filters, .js-message-filter-add', $root).toggleClass('is-hidden')
      if $root.hasClass('is-advanced')
        syncQueryFromAdvanced($root)
      else
        syncQuery($root)
    )

    .on('click', '.js-save-search', (event) ->
      event.preventDefault()
      $root = getRoot($(this))
      query = currentQueryValue($root)
      return unless query and query.length
      name = window.prompt('Name this search:')
      return unless name and name.length
      list = loadSavedSearches($root)
      list = (item for item in list when item.name isnt name)
      list.push(name: name, query: query)
      storeSavedSearches($root, list)
      renderSavedSearchOptions($root)
    )

    .on('change', '.js-saved-search-select', (event) ->
      $select = $(this)
      $root = getRoot($select)
      query = $select.val()
      return unless query and query.length
      $('.js-message-filter-query', $root).val(query)
      getForm($root).trigger('submit')
    )
