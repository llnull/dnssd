require 'helper'

class TestDNSSDService < DNSSD::Test

  def test_class_get_property
    skip 'DNSSD::Service::get_property not defined' unless
      DNSSD::Service.respond_to? :get_property

    assert_kind_of Numeric,
                   DNSSD::Service.get_property(DNSSD::Service::DaemonVersion)
  end

  def test_class_getaddrinfo
    addresses = []
    service = DNSSD::Service.getaddrinfo 'localhost'

    service.each do |addrinfo|
      addresses << addrinfo.address
      break unless addrinfo.flags.more_coming?
    end

    assert addresses.index('127.0.0.1')
  end

  def test_enumerate
    service = DNSSD::Service.enumerate_domains
    service.each do |reply|
      # I *think* there will be a local. on every machine??
      break if reply.domain == 'local.'
    end
    assert true
  end

  def test_two_threads_cannot_async
    register = DNSSD::Service.register name, "_http._tcp", nil, 8080
    running = Latch.new
    register.async_each { |_| running.release }
    running.await
    t = Thread.new { register.async_each { |_| } }
    register.stop

    assert_raises(DNSSD::Error) { t.join }
  end

  def test_async_register_browse
    registered = Latch.new
    found      = Latch.new
    name       = SecureRandom.hex

    register = DNSSD::Service.register name, "_http._tcp", nil, 8080
    register.async_each do |reply|
      if reply.domain == "local."
        registered.release
        found.await
      end
    end

    registered.await

    browse = DNSSD::Service.browse '_http._tcp'
    browse.async_each do |r|
      if r.name == name && r.domain == "local."
        found.release
        assert_equal name, r.name
        assert_equal "_http._tcp", r.type
      end
    end

    register.stop
    browse.stop
  end

  def test_register_browse
    registered = Latch.new
    found      = Latch.new
    name       = SecureRandom.hex

    broadcast = Thread.new do
      service = DNSSD::Service.register name, "_http._tcp", nil, 8080
      service.each do |reply|
        if reply.domain == "local."
          registered.release
          found.await
          service.stop
        end
      end
    end

    find = Thread.new do
      registered.await
      service = DNSSD::Service.browse '_http._tcp'
      service.each do |r|
        if r.name == name && r.domain == "local."
          found.release
          service.stop
          assert_equal name, r.name
          assert_equal "_http._tcp", r.type
        end
      end
    end

    found.await
    broadcast.join
    find.join
  end

  def test_resolve
    done = Latch.new
    name = SecureRandom.hex

    broadcast = Thread.new do
      txt = DNSSD::TextRecord.new 'foo' => 'bar'
      service = DNSSD::Service.register name, "_http._tcp", nil, 8080, nil, txt
      done.await
      service.stop
    end

    service = DNSSD::Service.browse '_http._tcp'
    reply = service.each.find do |r|
      r.name == name && r.domain == "local."
    end

    resolver = DNSSD::Service.resolve reply.name, reply.type, reply.domain
    text = resolver.each.find(&:text_record).text_record
    assert_equal 'bar', text['foo']

    done.release
    broadcast.join
  end

  def test_query_record
    done = Latch.new
    name = SecureRandom.hex

    broadcast = Thread.new do
      txt = DNSSD::TextRecord.new 'foo' => 'bar'
      service = DNSSD::Service.register name, "_http._tcp", nil, 8080, nil, txt
      done.await
      service.stop
    end

    service = DNSSD::Service.browse '_http._tcp'
    reply = service.each.find do |r|
      r.name == name && r.domain == "local."
    end
    service.stop

    service = DNSSD::Service.query_record reply.fullname, DNSSD::Record::SRV
    assert service.each.first
    service.stop

    done.release
    broadcast.join
  end

  def test_add_record
    done = Latch.new
    registered = Latch.new
    broadcast = Thread.new do
      txt = DNSSD::TextRecord.new 'bar' => 'baz'
      service = DNSSD::Service.register name, "_http._tcp", nil, 8080
      service.add_record(DNSSD::Record::TXT, txt.encode)
      registered.release
      done.await
    end

    registered.await
    service = DNSSD::Service.browse '_http._tcp'
    reply = service.each.find { |r|
      r.name == name && r.domain == "local."
    }

    query = DNSSD::Service.query_record reply.fullname, DNSSD::Record::TXT
    r = query.each.find do |r|
      !r.flags.more_coming?
    end
    record = DNSSD::TextRecord.decode r.record
    done.release
    assert_equal 'baz', record['bar']
    broadcast.join
  end

  def test_stop
    service = DNSSD::Service.browse '_http._tcp'
    assert_predicate service, :started?
    service.stop
    refute_predicate service, :started?

    assert_raises(DNSSD::Error) { service.each { } }
  end

  def test_stop_twice
    service = DNSSD::Service.browse '_http._tcp'
    service.stop
    assert_raises(DNSSD::Error) { service.stop }
  end
end
