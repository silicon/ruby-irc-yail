require 'rake/gempackagetask'
require 'rake/testtask'
require 'lib/net/yail/yail-version'
spec = Gem::Specification.new do |s|
  s.platform          = Gem::Platform::RUBY
  s.name              = "net-yail"
  s.version           = Net::YAIL::VERSION
  s.author            = "Jeremy Echols"
  s.email             = "yail<at>nerdbucket dot com"
  s.summary           = "Yet Another IRC Library: wrapper for IRC communications in Ruby."
  s.files             = FileList[ 'examples/simple/*', 'examples/logger/*', 'lib/net/*.rb', 'lib/net/yail/*', 'test/*.rb' ].to_a
  s.homepage          = 'http://ruby-irc-yail.nerdbucket.com/'
  s.rubyforge_project = 'net-yail'
  s.require_path      = "lib"
  s.autorequire       = "net/yail"
  s.test_files        = Dir.glob('tests/*.rb')
  s.has_rdoc          = true
  s.rdoc_options      = ['--main', 'YAIL-RDOC']
  s.extra_rdoc_files  = ['YAIL-RDOC']
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.need_tar = true
end

Rake::TestTask.new do |t|
  t.libs << "tests"
  t.test_files = FileList['tests/tc_*.rb']
  t.verbose = true
end

task :default => "pkg/#{spec.name}-#{spec.version}.gem" do
  puts "generated latest version"
end
