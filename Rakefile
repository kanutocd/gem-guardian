# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
end

task default: :test

namespace :rbs do
  desc "Remove generated RBS prototype files"
  task :clobber do
    sh "rm -rf tmp/sig"
  end

  desc "Generate disposable RBS prototypes into tmp/sig"
  task :prototype do
    sh "rm -rf tmp/sig"
    sh "mkdir -p tmp/sig"
    sh "bundle exec rbs prototype rb --out-dir=tmp/sig --base-dir=lib lib"

    unless Dir.exist?("sig")
      puts "sig/ does not exist; seeding curated signatures from tmp/sig"
      sh "cp -R tmp/sig sig"
    end
  end

  desc "Validate curated RBS signatures with Steep"
  task :validate do
    sh "bundle exec rbs validate sig"
  end

  desc "Open diff between curated and generated signatures"
  task :diff do
    sh "diff -ru sig tmp/sig || true"
  end

  desc "Generate disposable RBS prototypes and validate curated signatures"
  task check: %i[prototype validate]
end
