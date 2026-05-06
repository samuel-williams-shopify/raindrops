# frozen_string_literal: true
#
# Comparison test: Raindrops (inet_diag) vs io-metrics (/proc/net/tcp).
#
# Both libraries measure TCP listener activity but use different kernel
# interfaces and different connection-state coverage:
#
#   Raindrops  — netlink inet_diag, ESTABLISHED (inode != 0) only → .active
#   io-metrics — /proc/net/tcp,    ESTABLISHED (minus backlog)    → .active_count
#                                  CLOSE_WAIT                     → .close_wait_count
#
# The core identity this test verifies is:
#
#   raindrops.active + io_metrics.close_wait_count ≈ io_metrics.active_count + io_metrics.close_wait_count
#   i.e. raindrops.active ≈ io_metrics.active_count
#
# and the full relationship:
#
#   requests_active ≈ raindrops.active + io_metrics.close_wait_count
#
# Scenarios tested:
#   1. Idle listener                  → both: active=0, queued=0
#   2. Queued (not yet accepted)      → both: active=0, queued=N
#   3. Active (accepted, ESTABLISHED) → both: active=N, queued=0
#   4. CLOSE_WAIT (client closed)     → raindrops: active=0, io-metrics: close_wait_count=1
#   5. Mixed active + CLOSE_WAIT      → raindrops: active=N, io-metrics: active_count=N, close_wait_count=M
#   6. Server-side close (FIN_WAIT2)  → both: active=0 (invisible to both)

require 'test/unit'
require 'socket'
require 'io/metrics'
$stderr.sync = $stdout.sync = true

# Skip entire file on non-Linux or if either backend is unavailable.
unless RUBY_PLATFORM.include?('linux')
  puts "Skipping #{__FILE__}: Linux only"
  return
end

unless defined?(Raindrops::Linux) && Raindrops::Linux.respond_to?(:tcp_listener_stats)
  puts "Skipping #{__FILE__}: Raindrops::Linux.tcp_listener_stats not available"
  return
end

unless IO::Metrics::Listener.supported?
  puts "Skipping #{__FILE__}: io-metrics /proc/net/tcp not available"
  return
end

require 'raindrops'

class TestLinuxIoMetricsComparison < Test::Unit::TestCase

  # ── helpers ──────────────────────────────────────────────────────────────────

  def setup
    @to_close = []
    @server   = nil
    @address  = nil
  end

  def teardown
    @to_close.each { |io| io.close rescue nil }
    @server&.close rescue nil
  end

  # Open a fresh TCPServer on a random port and record the canonical address string.
  def open_server
    @server  = TCPServer.new('127.0.0.1', 0)
    @port    = @server.addr[1]
    @address = "127.0.0.1:#{@port}"
  end

  # Snapshot both backends for @address and return a pair [raindrops_stats, io_metrics_listener].
  # raindrops_stats is a Raindrops::ListenStats (or nil if not found).
  # io_metrics_listener is an IO::Metrics::Listener (or nil if not found).
  def sample
    rd_all  = Raindrops::Linux.tcp_listener_stats([@address])
    rd      = rd_all[@address]

    iom_all = IO::Metrics::Listener.capture(addresses: [@address])
    iom     = iom_all&.first

    [rd, iom]
  end

  # Wait up to +timeout+ seconds for the block to return true, polling every 10 ms.
  def wait_until(timeout: 2.0, msg: "condition never met")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise "#{msg} (waited #{timeout}s)" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  # ── scenario 1: idle ─────────────────────────────────────────────────────────

  def test_01_idle_listener
    open_server
    rd, iom = sample

    assert_not_nil rd,  "Raindrops should see the idle listener"
    assert_not_nil iom, "io-metrics should see the idle listener"

    assert_equal 0, rd.active,             "raindrops.active should be 0 (idle)"
    assert_equal 0, rd.queued,             "raindrops.queued should be 0 (idle)"
    assert_equal 0, iom.active_count,      "io-metrics.active_count should be 0 (idle)"
    assert_equal 0, iom.queued_count,      "io-metrics.queued_count should be 0 (idle)"
    assert_equal 0, iom.close_wait_count,  "io-metrics.close_wait_count should be 0 (idle)"
  end

  # ── scenario 2: connections in the backlog (not yet accepted) ────────────────

  def test_02_queued_not_accepted
    open_server
    n = 3
    n.times { @to_close << TCPSocket.new('127.0.0.1', @port) }

    wait_until(msg: "both backends to show queued=#{n}") do
      rd, iom = sample
      rd&.queued.to_i >= n && iom&.queued_count.to_i >= n
    end

    rd, iom = sample

    # Both must agree: these connections are queued, not active.
    assert_equal n, rd.queued,   "raindrops.queued should be #{n}"
    assert_equal 0, rd.active,   "raindrops.active should be 0 (none accepted)"
    assert_equal n, iom.queued_count,  "io-metrics.queued_count should be #{n}"
    assert_equal 0, iom.active_count,  "io-metrics.active_count should be 0 (none accepted)"
    assert_equal 0, iom.close_wait_count, "io-metrics.close_wait_count should be 0"

    puts "\n[scenario 2] queued=#{n}: raindrops.queued=#{rd.queued} io-metrics.queued=#{iom.queued_count}"
  end

  # ── scenario 3: accepted, ESTABLISHED connections ────────────────────────────

  def test_03_active_established
    open_server
    n = 4
    n.times { @to_close << TCPSocket.new('127.0.0.1', @port) }
    n.times { @to_close << @server.accept }
    sleep 0.05

    rd, iom = sample

    # Both backends should agree on the active count.
    assert_operator rd.active, :>=, n,
      "raindrops.active should be >= #{n} (got #{rd.active})"
    assert_operator iom.active_count, :>=, n,
      "io-metrics.active_count should be >= #{n} (got #{iom.active_count})"
    assert_equal 0, iom.close_wait_count,
      "io-metrics.close_wait_count should be 0 (all ESTABLISHED)"

    # The two active counts should agree (same connections, same state).
    diff = (rd.active - iom.active_count).abs
    assert_operator diff, :<=, 1,
      "raindrops.active (#{rd.active}) and io-metrics.active_count (#{iom.active_count}) " \
      "should agree within ±1"

    puts "\n[scenario 3] active=#{n}: raindrops.active=#{rd.active} " \
         "io-metrics.active_count=#{iom.active_count} " \
         "io-metrics.close_wait_count=#{iom.close_wait_count}"
  end

  # ── scenario 4: CLOSE_WAIT — client closes, server holds the fd ──────────────

  def test_04_close_wait_client_closes_server_holds
    open_server
    client   = TCPSocket.new('127.0.0.1', @port)
    accepted = @server.accept
    @to_close << accepted  # server side stays open throughout the test

    # Let the connection settle.
    sleep 0.05
    rd_before, iom_before = sample

    # Client closes its end → server socket transitions to CLOSE_WAIT.
    client.close
    sleep 0.1

    rd_after, iom_after = sample

    # Raindrops uses inet_diag with only TCP_ESTABLISHED in its state mask.
    # A CLOSE_WAIT socket is NOT in TCP_ESTABLISHED — it drops to 0.
    assert_equal 0, rd_after.active,
      "raindrops.active should be 0 after client closes (CLOSE_WAIT invisible to inet_diag)"

    # io-metrics reads /proc/net/tcp and explicitly counts TCP_CLOSE_WAIT.
    assert_operator iom_after.close_wait_count, :>=, 1,
      "io-metrics.close_wait_count should be >= 1 (server still holds fd)"

    # io-metrics.active_count should also drop since the connection left ESTABLISHED.
    assert_equal 0, iom_after.active_count,
      "io-metrics.active_count should be 0 (connection is now CLOSE_WAIT, not ESTABLISHED)"

    puts "\n[scenario 4] after client close:"
    puts "  Before: raindrops.active=#{rd_before.active}  " \
         "io-metrics.active_count=#{iom_before.active_count}  " \
         "io-metrics.close_wait_count=#{iom_before.close_wait_count}"
    puts "  After:  raindrops.active=#{rd_after.active}  " \
         "io-metrics.active_count=#{iom_after.active_count}  " \
         "io-metrics.close_wait_count=#{iom_after.close_wait_count}"
    puts "  → CLOSE_WAIT gap: #{iom_after.close_wait_count} connections invisible to raindrops"
  end

  # ── scenario 5: mixed ESTABLISHED + CLOSE_WAIT ───────────────────────────────
  #
  # This is the steady-state production scenario: some requests are in-flight
  # (ESTABLISHED), some are in post-response cleanup (CLOSE_WAIT).
  #
  # Expected:
  #   raindrops.active             == n_established
  #   io-metrics.active_count      == n_established
  #   io-metrics.close_wait_count  == n_close_wait
  #
  # Identity:
  #   requests_active ≈ raindrops.active + io-metrics.close_wait_count

  def test_05_mixed_established_and_close_wait
    open_server
    n_established = 3
    n_close_wait  = 2

    # Establish n_established connections that stay open.
    established_clients   = n_established.times.map { TCPSocket.new('127.0.0.1', @port) }
    established_accepted  = n_established.times.map { @server.accept }
    @to_close.concat(established_clients + established_accepted)

    # Establish n_close_wait connections, then close only the client side.
    cw_clients   = n_close_wait.times.map { TCPSocket.new('127.0.0.1', @port) }
    cw_accepted  = n_close_wait.times.map { @server.accept }
    @to_close.concat(cw_accepted)  # server holds these open
    cw_clients.each(&:close)       # client closes → server side becomes CLOSE_WAIT

    sleep 0.1

    rd, iom = sample

    # Raindrops only sees ESTABLISHED — the CLOSE_WAIT connections are invisible.
    assert_operator rd.active, :>=, n_established,
      "raindrops.active should be >= #{n_established} (ESTABLISHED only)"

    # io-metrics active_count should match raindrops (both count ESTABLISHED).
    diff = (rd.active - iom.active_count).abs
    assert_operator diff, :<=, 1,
      "raindrops.active (#{rd.active}) and io-metrics.active_count (#{iom.active_count}) " \
      "should agree within ±1 for ESTABLISHED connections"

    # io-metrics should see the CLOSE_WAIT connections.
    assert_operator iom.close_wait_count, :>=, n_close_wait,
      "io-metrics.close_wait_count should be >= #{n_close_wait}"

    # The identity: requests_active ≈ raindrops.active + io-metrics.close_wait_count
    simulated_requests_active = rd.active + iom.close_wait_count

    puts "\n[scenario 5] mixed ESTABLISHED=#{n_established} + CLOSE_WAIT=#{n_close_wait}:"
    puts "  raindrops.active             = #{rd.active}"
    puts "  io-metrics.active_count      = #{iom.active_count}"
    puts "  io-metrics.close_wait_count  = #{iom.close_wait_count}"
    puts "  simulated requests_active    = #{simulated_requests_active}"
    puts "  (raindrops alone undercounts by #{iom.close_wait_count} connection(s))"
  end

  # ── scenario 6: server closes first (FIN_WAIT2) ──────────────────────────────
  #
  # When the server closes its end first but the client is still connected, the
  # server socket enters FIN_WAIT1 → FIN_WAIT2.  Neither backend counts this state.
  # Once the client also closes, the socket becomes TIME_WAIT (also not counted).

  def test_06_server_closes_first_fin_wait
    open_server
    client   = TCPSocket.new('127.0.0.1', @port)
    accepted = @server.accept
    @to_close << client  # keep client open so server can't get past FIN_WAIT2

    sleep 0.05
    rd_before, iom_before = sample

    # Server closes its end → FIN_WAIT1/FIN_WAIT2 on the server side.
    accepted.close
    sleep 0.1

    rd_after, iom_after = sample

    # Neither backend tracks FIN_WAIT — both should show active=0.
    assert_equal 0, rd_after.active,
      "raindrops.active should be 0 after server close (FIN_WAIT2 invisible to inet_diag)"
    assert_equal 0, iom_after.active_count,
      "io-metrics.active_count should be 0 (FIN_WAIT2 not ESTABLISHED)"
    assert_equal 0, iom_after.close_wait_count,
      "io-metrics.close_wait_count should be 0 (FIN_WAIT2 is on server side, not CLOSE_WAIT)"

    puts "\n[scenario 6] server closes first (FIN_WAIT2):"
    puts "  Before: raindrops.active=#{rd_before.active}  " \
         "io-metrics.active_count=#{iom_before.active_count}"
    puts "  After:  raindrops.active=#{rd_after.active}  " \
         "io-metrics.active_count=#{iom_after.active_count}  " \
         "io-metrics.close_wait_count=#{iom_after.close_wait_count}"
    puts "  → FIN_WAIT2 is invisible to both backends"
  end

  # ── scenario 7: scale — many connections ─────────────────────────────────────

  def test_07_scale_many_connections
    open_server
    n = 20
    clients  = n.times.map { TCPSocket.new('127.0.0.1', @port) }
    accepted = n.times.map { @server.accept }
    @to_close.concat(clients + accepted)
    sleep 0.1

    rd, iom = sample

    assert_operator rd.active, :>=, n,
      "raindrops.active should be >= #{n}"
    assert_operator iom.active_count, :>=, n,
      "io-metrics.active_count should be >= #{n}"
    assert_equal 0, iom.close_wait_count,
      "io-metrics.close_wait_count should be 0 (all ESTABLISHED)"

    diff = (rd.active - iom.active_count).abs
    assert_operator diff, :<=, 2,
      "raindrops.active (#{rd.active}) and io-metrics.active_count (#{iom.active_count}) " \
      "should agree within ±2 at scale"

    # Now close half the clients → half become CLOSE_WAIT on server side.
    half = n / 2
    clients.first(half).each(&:close)
    sleep 0.1

    rd2, iom2 = sample

    assert_operator rd2.active, :>=, n - half,
      "raindrops.active should be >= #{n - half} after #{half} clients close"
    assert_operator iom2.close_wait_count, :>=, half,
      "io-metrics.close_wait_count should be >= #{half} after #{half} clients close"

    puts "\n[scenario 7] scale=#{n}, then close #{half} clients:"
    puts "  Phase 1: raindrops.active=#{rd.active}  " \
         "io-metrics.active_count=#{iom.active_count}"
    puts "  Phase 2: raindrops.active=#{rd2.active}  " \
         "io-metrics.active_count=#{iom2.active_count}  " \
         "io-metrics.close_wait_count=#{iom2.close_wait_count}"
    puts "  requests_active estimate = #{rd2.active + iom2.close_wait_count} " \
         "(= #{rd2.active} established + #{iom2.close_wait_count} close_wait)"
  end

end
