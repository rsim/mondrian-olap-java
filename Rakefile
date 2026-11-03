require 'bundler/setup'

desc 'Run tests (default)'
task :default => :test

require_relative 'test/rake_tasks'

def release_version
  File.read("pom.xml")[%r{<revision>(.+)</revision>}, 1] || abort("ERROR: pom.xml does not have the <revision> property")
end

def release_tag
  "v#{release_version}"
end

namespace :release do
  desc "Check that the current version is ready for the release"
  task :check do
    version = release_version
    errors = []

    if version.include?("SNAPSHOT")
      errors << "Snapshot version #{version} cannot be released, update the <revision> in pom.xml"
    end

    current_branch = `git rev-parse --abbrev-ref HEAD`.strip
    unless current_branch == "master"
      errors << "Release from the master branch, the current branch is #{current_branch}"
    end

    unless `git status --porcelain`.strip.empty?
      errors << "There are uncommitted changes, commit them before the release"
    end

    sh "git fetch --quiet origin master"
    unless `git rev-parse HEAD`.strip == `git rev-parse origin/master`.strip
      errors << "The master branch is not in sync with origin/master, push or pull the changes before the release"
    end

    if system("git rev-parse --quiet --verify refs/tags/#{release_tag}", out: File::NULL) ||
        !`git ls-remote --tags origin refs/tags/#{release_tag}`.strip.empty?
      errors << "Tag #{release_tag} already exists"
    end

    abort errors.map { |error| "ERROR: #{error}" }.join("\n") unless errors.empty?
  end

  desc "Create the version tag and push it to origin"
  task :tag => :check do
    sh "git tag #{release_tag}"
    sh "git push origin #{release_tag}"
  end
end
