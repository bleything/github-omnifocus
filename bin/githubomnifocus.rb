#!/usr/bin/env ruby

require 'bundler/setup'

require 'octokit'
require 'rb-scpt'

require 'yaml'

Octokit.auto_paginate = true

def get_issues
  github_issues = Hash.new

  @github.list_issues.each do |issue|
    number    = issue.number
    project   = issue.repository.full_name.split("/").last
    issue_id = "#{project}-##{number}"

    github_issues[issue_id] = issue
  end

  return github_issues
end

# This method adds a new Task to OmniFocus based on the new_task_properties passed in
def add_task(omnifocus_document, new_task_properties)
  # If there is a passed in OF project name, get the actual project object
  if new_task_properties['project']
    proj_name = new_task_properties["project"]
    proj = omnifocus_document.flattened_tasks[proj_name]
  end

  # Check to see if there's already an OF Task with that name in the referenced Project
  # If there is, just stop.
  name   = new_task_properties["name"]
  #exists = proj.tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
  # You can un-comment the line below and comment the line above if you want to search your entire OF document, instead of a specific project.
  exists = omnifocus_document.flattened_tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
  return false if exists

  # If there is a passed in OF context name, get the actual context object
  if new_task_properties['context']
    ctx_name = new_task_properties["context"]
    ctx = omnifocus_document.flattened_contexts[ctx_name]
  end

  # Do some task property filtering.  I don't know what this is for, but found it in several other scripts that didn't work...
  tprops = new_task_properties.inject({}) do |h, (k, v)|
    h[:"#{k}"] = v
    h
  end

  # Remove the project property from the new Task properties, as it won't be used like that.
  tprops.delete(:project)
  # Update the context property to be the actual context object not the context name
  tprops[:context] = ctx if new_task_properties['context']

  # You can uncomment this line and comment the one below if you want the tasks to end up in your Inbox instead of a specific Project
  #  new_task = omnifocus_document.make(new: :inbox_task, with_properties: tprops)

  # Make a new Task in the Project
  proj.make(new: :task, with_properties: tprops)

  puts "Created task " + tprops[:name]
  return true
end

# This method is responsible for getting your assigned GitHub Issues and adding them to OmniFocus as Tasks
def add_github_issues_to_omnifocus (omnifocus_document)
  # Get the open Jira issues assigned to you
  results = get_issues
  if results.nil?
    puts "No results from GitHub"
    exit
  end

  # Iterate through resulting issues.
  results.each do |issue_id, issue|
    pr        = issue["pull_request"] && !issue["pull_request"]["diff_url"].nil?
    number    = issue.number
    project   = issue.repository.full_name.split("/").last
    issue_id = "#{project}-##{number}"
    title     = "#{issue_id}: #{pr ? "[PR] " : ""}#{issue["title"]}"
    url       = "https://github.com/#{issue.repository.full_name}/issues/#{number}"
    note      = "#{url}\n\n#{issue["body"]}"

    task_name = title
    # Create the task notes with the GitHub Issue URL and issue body
    task_notes = note

    # Build properties for the Task
    @props = {}
    @props['name'] = task_name
    @props['project'] = @project
    @props['context'] = @context
    @props['note'] = task_notes
    @props['flagged'] = @flag

    add_task(omnifocus_document, @props)
  end
end

def mark_resolved_github_issues_as_complete_in_omnifocus (omnifocus_document)
  # get tasks from the project
  ctx = omnifocus_document.flattened_contexts[@context]
  ctx.tasks.get.find.each do |task|
    if !task.completed.get && task.note.get.match('github')
      note = task.note.get
      repo, number = note.match(/https:\/\/github.com\/(.*)?\/issues\/(.*)/i).captures

      issue = @github.issue(repo, number)
      if issue != nil
        if issue.state == 'closed'
          # if resolved, mark it as complete in OmniFocus
          if task.completed.get != true
            task.mark_complete()
            number    = issue.number
            puts "Marked task completed " + number.to_s
          end
        end

        # Check to see if the GitHub issue has been unassigned or assigned to someone else, if so delete it.
        # It will be re-created if it is assigned back to you.
        if ! issue.assignee
          omnifocus_document.delete task
        else
          assignee = issue.assignee.login.downcase
          if assignee != @username.downcase
            omnifocus_document.delete task
          end
        end
      end
    end
  end
end

if $0 == __FILE__
  config_path = "#{ENV['HOME']}/.ghofsync.yaml"

  unless File.file? config_path
    $stderr.puts "You must create ~/.ghofsync.yaml to continue. See the README for details."
    exit 1
  end

  config = YAML.load_file(config_path)
  creds = config['github']

  @username = config['github']['username']
  @password = config['github']['password']
  @oauth    = config['github']['oauth']
  @context  = config['omnifocus']['context']
  @project  = config['omnifocus']['project']
  @flag     = config['omnifocus']['flag']

  if @username and @password
    @github = Octokit::Client.new(login: @username, password: @password)
  elsif @username and @oauth
    @github = Octokit::Client.new(access_token: @oauth)
  else
    $stderr.puts "No username and password or username and oauth token combo found!"
    exit 1
  end

  @github.user.login

  omnifocus_document = Appscript.app.by_name("OmniFocus").default_document
  add_github_issues_to_omnifocus(omnifocus_document)
  mark_resolved_github_issues_as_complete_in_omnifocus(omnifocus_document)
end
