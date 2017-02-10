#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Copyright (C) 2016-1017 Harald Sitter <sitter@kde.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 3 of
# the License or any later version accepted by the membership of
# KDE e.V. (or its successor approved by the membership of KDE
# e.V.), which shall act as a proxy defined in Section 14 of
# version 3 of the license.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'date'
require 'faraday'
require 'pp'

require_relative 'lib/jsonrpc'

JSONRPCConnector.user = 'jsonrpc'
JSONRPCConnector.token = '123asdf'

# Conduit token
PHAB_TOKEN = 'asdf123'.freeze
# Phid of the user the token belongs to (used to unsub from tasks)
PHAN_USER_PHID = 'PHID-USER-4kerus6xjnzeqjtp3t2k'.freeze

# Internal Project ID in kanboard
# 87 = neon
# 58 = kdeev
# kmymoney = 16
# l10n = 22
# plasma on wayland = 2
# brazil = 17
# kdeconnect = 45
CANBAN_PROJECT = '45'.freeze

# Internal Project PHID in phabricator of where to move tasks to.
# kdeev = PHID-PROJ-jef2y5ssgpovlnqmrt5n
# kmymoney = PHID-PROJ-jpzzjbwhjqfsumropbyl
# l10n = PHID-PROJ-27h5oandgrosjnf6wlgn
# plasma on wayland = PHID-PROJ-gciz2qlsumln5yuo6kr2
# brazil = PHID-PROJ-nsvmstxtykvfxkau6kph
# kdeconnect = PHID-PROJ-zsciskdq7b7zkd3jvaz5
PHAB_PROJECT = 'PHID-PROJ-zsciskdq7b7zkd3jvaz5'.freeze

# Pointless columns such as 'Closed' or 'Done' which need not be migrated.
pointless_columns = %w(370 371 372 373) + # neon
                    %w(247) + # kdeev
                    %w(84) + # kmymoney
                    %w(108) + # l10n
                    %w(10 11) + # kwin
                    %w(88) + # brazil
                    %w(184 185) # kdeconnect

# ------------------------- Grab Data From Kanboard -------------------------

client = JSONRPC::Client.new('https://todo.kde.org/jsonrpc.php')
tasks = client.getAllTasks(CANBAN_PROJECT, '1')
tasks = tasks.select { |t| !pointless_columns.include?(t['column_id']) }

# Helper class grabbing comment data out of Kanboard and storing them in-memory
# Primarily so we have all data at hand before we start talking to phab. Avoids
# connection problems half way through rendering our data set incomplete.
class ProtoTask
  attr_accessor :task
  attr_accessor :comments
  attr_accessor :assignee

  def initialize
    @comments = []
  end

  def time(comment)
    Time.at(comment.fetch('date').to_i).utc.to_s
  end

  def self.from_kanboard(client, task)
    proto = new
    proto.task = task
    proto.comments = client.getAllComments(t['id'])
    proto.comments.sort_by! { |x| x['date'] }
    if task['owner_id'] && task['owner_id'] != '0'
      user = client.getUser(task['owner_id'])
      proto.assignee = user['username'] if user
    end
    proto
  end
end

proto_tasks = tasks.collect { |t| ProtoTask.from_kanboard(client, t) }

pp proto_tasks

# ------------------------- Hurl Data at Phabricator ------------------------

# There is no reasonably good looking/maintained phabricator gem. Use some
# Faraday spagetthi instead so I at least know it uses the API correctly...
conn = Faraday.new(url: 'https://phabricator.kde.org/api',
                   params: { 'api.token' => PHAB_TOKEN }) do |c|
  c.request :url_encoded
  c.response :logger, ::Logger.new(STDOUT), bodies: true
  c.adapter Faraday.default_adapter
end

# Create new task in maniphest
tasks.each do |task|
  resp = conn.get('maniphest.createtask') do |req|
    title = task.fetch('title')
    description = task.fetch('description')
    req.params['title'] = title
    req.params['description'] = description
    req.params['projectPHIDs'] = [PHAB_PROJECT]
  end
  p JSON.parse(resp.body).fetch('result').fetch('phid')
end

# Naughty hack to obtain all tasks now on the board, this is because above this
# information is not stored AND when running the script multiple times tasks
# may already exist and thus not created but still need information from
# proto tasks filled in.
phab_tasks = conn.get('maniphest.query') do |req|
  req.params['projectPHIDs'] = [PHAB_PROJECT]
end
phab_tasks = JSON.parse(phab_tasks.body).fetch('result')

# Shove proto task information (i.e. comments) into maniphest tasks.
proto_tasks.each do |proto|
  task = proto.task
  title = task.fetch('title')
  # Matches by title, super unrelable but best reentrant approach
  phid = phab_tasks.find { |x| x[1]['title'] == title }[0]

  proto.comments.each do |comment|
    body = "Originally made by #{comment.fetch('username', 'Unknown')} at #{proto.time(comment)}\n\n#{comment.fetch('comment')}"
    resp = conn.get('maniphest.edit') do |req|
      transaction = { 'type' => 'comment', 'value' => body }
      req.params['transactions'] = { '0' => transaction }
      req.params['objectIdentifier'] = phid
      # puts JSON.generate(req.params)
    end
    pp JSON.parse resp.body
    # exit
  end
end

# Remove me from subscribers so I don't get mails for subsequent work on the
# maniphest tasks.
phab_tasks.each do |phid|
  phid = phid[0]
  resp = conn.get('maniphest.edit') do |req|
    transaction = { 'type' => 'subscribers.remove', 'value' => [PHAN_USER_PHID] }
    req.params['transactions'] = { '0' => transaction }
    req.params['objectIdentifier'] = phid
    puts JSON.generate(req.params)
  end
  pp JSON.parse resp.body
end
