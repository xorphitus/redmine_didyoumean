# -*- coding: utf-8 -*-
require 'okura/serializer'

class SearchIssuesController < ApplicationController
  unloadable

  DEFAULT_LIMIT = 5

  def index
    @query = (params[:query] || "").strip

    logger.debug "Got request for [#{@query}]"
    logger.debug "Did you mean settings: #{Setting.plugin_redmine_didyoumean.to_json}"

    all_words = true # if true, returns records that contain all the words specified in the input query
    min_length = Setting.plugin_redmine_didyoumean['min_word_length'].to_i

    # extract tokens from the query
    # eg. hello "bye bye" => ["hello", "bye bye"]
    @tokens = (to_nouns(@query).concat @query.scan(/\w+/))
      .uniq
      .select {|token| token.length >= min_length}

    if @tokens.present?
      # no more than 5 tokens to search for
      # this is probably too strict, in this use case
      @tokens.slice! 5..-1 if @tokens.size > 5
      @tokens.map! {|token| "%#{token}%"}

      separator = all_words ? ' AND ' : ' OR '

      limit = Setting.plugin_redmine_didyoumean['limit'] || DEFAULT_LIMIT
      conditions = query_conditions(@tokens, separator)
      # order by decreasing creation time. Some relevance sort would be a lot more appropriate here
      @issues = Issue.visible.find(:all, :conditions => conditions, :limit => limit, :order => '"issues"."id" DESC')
      @count = Issue.visible.count(:all, :conditions => conditions)

      logger.debug "#{@count} results found, returning the first #{@issues.length}"
    else
      @query = ""
      @count = 0
      @issues = []
    end

    render :json => {:total => @count, :issues => @issues.map{|issue|
        { #make a deep copy, otherwise rails3 makes weird stuff nesting the issue as mapping.
          :id => issue.id,
          :tracker_name => issue.tracker.name,
          :subject => issue.subject,
          :status_name => issue.status.name,
          :project_name => issue.project.name
        }
      }}
  end

  private
  def query_conditions tokens, separator
    # pick the current project
    project = Project.find(params[:project_id]) if params[:project_id].present?
    project_tree = to_project_tree(project, Setting.plugin_redmine_didyoumean['project_filter'])

    additional_conditions, additional_variables = additional_params(project_tree, params[:issue_id])
    conditions = (['lower(subject) like lower(?)'] * tokens.length).join(separator) + additional_conditions
    variables = tokens.concat additional_variables

    [conditions, *variables]
  end

  def to_project_tree project, project_filter
    case project_filter
    when '2'
      Project.all
    when '1'
      # search subprojects too
      project ? (project.self_and_descendants.active) : nil
    when '0'
      [project]
    else
      logger.warn "Unrecognized option for project filter: [#{Setting.plugin_redmine_didyoumean['project_filter']}], skipping"
      nil
    end
  end

  def additional_params project_tree, issue_id
    additional_conditions = ''
    additional_variables = []

    if project_tree
      # check permissions
      scope = project_tree.select {|project| User.current.allowed_to?(:view_issues, project)}
      logger.debug "Set project filter to #{scope}"
      additional_conditions += " AND project_id in (?)"
      additional_variables << scope
    end

    if Setting.plugin_redmine_didyoumean['show_only_open'] == "1"
      valid_statuses = IssueStatus.all(:conditions => ["is_closed <> ?", true])
      logger.debug "Valid status ids are #{valid_statuses}"
      additional_conditions += " AND status_id in (?)"
      additional_variables << valid_statuses
    end

    if issue_id.present?
      logger.debug "Excluding issue #{issue_id}"
      additional_conditions += " AND issues.id != (?)"
      additional_variables << issue_id
    end

    [additional_conditions, additional_variables]
  end

  @@tagger = Okura::Serializer::FormatInfo.create_tagger Setting.plugin_redmine_didyoumean['dictionary_path']
  def to_nouns str
    @@tagger.parse(str).mincost_path
      .map {|node| node.word}
      .select {|word| word.left.text.match /^名詞,/}
      .map {|word| word.surface}
  end
end
