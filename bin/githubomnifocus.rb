#!/usr/bin/env ruby

require 'bundler/setup'

require 'octokit'
require 'rb-scpt'

require 'yaml'

Octokit.auto_paginate = true

# This method adds a new Task to OmniFocus based on the new_task_properties passed in
def add_task(task)
  # Check to see if there's already an OF Task with that name in the referenced Project
  # If there is, just stop.
  name = task[:name]
  #exists = proj.tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
  # You can un-comment the line below and comment the line above if you want to search your entire OF document, instead of a specific project.
  exists = @omnifocus.flattened_tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
  return false if exists

  task[:context] = @omnifocus.flattened_contexts[@context]
  task[:flagged] = @flag

  # You can uncomment this line and comment the one below if you want the tasks to end up in your Inbox instead of a specific Project
  #  new_task = @omnifocus.make(new: :inbox_task, with_properties: tprops)

  # Make a new Task in the Project
  @omnifocus.flattened_tasks[@project].make(new: :task, with_properties: task)

  puts "Created task " + task[:name]
  return true
end

# This method is responsible for getting your assigned GitHub Issues and adding them to OmniFocus as Tasks
def add_github_issues_to_omnifocus
  # Get the open GitHub issues assigned to you
  results = {}

  @github.list_issues.each do |issue|
    number    = issue.number
    project   = issue.repository.full_name.split("/").last
    issue_id = "#{project}-##{number}"

    results[issue_id] = issue
  end

  if results.empty?
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

    add_task(name: title, note: note)
  end
end

def mark_resolved_github_issues_as_complete_in_omnifocus
  # get tasks from the project
  ctx = @omnifocus.flattened_contexts[@context]
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
          @omnifocus.delete task
        else
          assignee = issue.assignee.login.downcase
          if assignee != @username.downcase
            @omnifocus.delete task
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
  @context  = config['omnifocus']['context']
  @project  = config['omnifocus']['project']
  @flag     = config['omnifocus']['flag']

  password = config['github']['password']
  token    = config['github']['token']

  if @username and password
    @github = Octokit::Client.new(login: @username, password: password)
  elsif @username and token
    @github = Octokit::Client.new(access_token: token)
  else
    $stderr.puts "No username and password or username and token combo found!"
    exit 1
  end

  @github.user.login
  @omnifocus = Appscript.app.by_name("OmniFocus").default_document

  add_github_issues_to_omnifocus
  mark_resolved_github_issues_as_complete_in_omnifocus
end
