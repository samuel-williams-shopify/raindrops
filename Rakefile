RUBY_VERSIONS = %w[3.4 4.0].freeze
TEST_FILES = %w[
  test/test_raindrops.rb
  test/test_raindrops_gc.rb
  test/test_struct.rb
  test/test_linux.rb
  test/test_tcp_info.rb
  test/test_inet_diag_socket.rb
  test/test_linux_io_metrics_comparison.rb
].freeze

namespace :test do
  desc "Run tests in podman for all supported Ruby versions (#{RUBY_VERSIONS.join(', ')})"
  task :podman do
    failed = []
    RUBY_VERSIONS.each do |version|
      puts "\n#{'=' * 60}"
      puts "Testing Ruby #{version}"
      puts '=' * 60
      ok = system(
        "podman", "run", "--rm", "--privileged",
        "-v", "#{Dir.pwd}:/app:z", "-w", "/app",
        "ruby:#{version}",
        "bash", "-c", <<~SH
          gem install test-unit --no-document &&
          cd ext/raindrops &&
          rm -f extconf.h Makefile *.o *.so &&
          ruby extconf.rb &&
          make &&
          cd ../.. &&
          ruby -I ext/raindrops -I lib -I test -e '
            require "test-unit"
            #{TEST_FILES.map { |f| %Q(require "./#{f}") }.join("; ")}
          '
        SH
      )
      failed << version unless ok
    end

    if failed.any?
      abort "\nFAILED on Ruby: #{failed.join(', ')}"
    else
      puts "\nAll versions passed."
    end
  end
end

desc "Run tests in podman (alias for test:podman)"
task test: "test:podman"
