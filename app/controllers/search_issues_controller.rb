# -*- coding: utf-8 -*-
require 'okura/serializer'

class SearchIssuesController < ApplicationController
  unloadable

  DEFAULT_LIMIT = 5

  def index
    @query = params[:query] || ""
    @query.strip!

    logger.debug "Got request for [#{@query}]"
    logger.debug "Did you mean settings: #{Setting.plugin_redmine_didyoumean.to_json}"

    all_words = true # if true, returns records that contain all the words specified in the input query

    # extract tokens from the query
    # eg. hello "bye bye" => ["hello", "bye bye"]
    @tokens = to_nouns(@query).concat @query.scan(/\w+/)

    min_length = Setting.plugin_redmine_didyoumean['min_word_length'].to_i
    @tokens = @tokens.uniq.select {|w| w.length >= min_length}

    if @tokens.present?
      # no more than 5 tokens to search for
      # this is probably too strict, in this use case
      @tokens.slice! 5..-1 if @tokens.size > 5

      separator = all_words ? ' AND ' : ' OR '

      @tokens.map! {|cur| "%#{cur}%"}

      conditions = (['lower(subject) like lower(?)'] * @tokens.length).join(separator)
      variables = @tokens

      # pick the current project
      project = Project.find(params[:project_id]) unless params[:project_id].blank?

      # when editing an existing issue this will hold its id
      issue_id = params[:issue_id] unless params[:issue_id].blank?

      project_tree = to_project_tree project, Setting.plugin_redmine_didyoumean['project_filter']

      additional_conditions, additional_variables = additional_params(project_tree, issue_id)
      conditions += additional_conditions
      variables = variables.concat additional_variables

      limit = Setting.plugin_redmine_didyoumean['limit'] || DEFAULT_LIMIT

      # order by decreasing creation time. Some relevance sort would be a lot more appropriate here
      @issues = Issue.visible.find(:all, :conditions => [conditions, *variables], :limit => limit, :order => '"issues"."id" DESC')
      @count = Issue.visible.count(:all, :conditions => [conditions, *variables])

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
  def to_project_tree project, project_filter
    case project_filter
    when '2'
      project_tree = Project.all
    when '1'
      # search subprojects too
      project_tree = project ? (project.self_and_descendants.active) : nil
    when '0'
      project_tree = [project]
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

    if !issue_id.nil?
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
