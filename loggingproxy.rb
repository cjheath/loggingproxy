#! /usr/bin/ruby
#
# Simple TCP (or HTTP) proxy with logging features, for snooping on TCP or HTTP streams.
# (c) Copyright 2010, Clifford Heath. Released under the MIT license.
#

require 'getoptlong'
require 'socket'
require 'thread'

module Net
  class LoggingProxy
    def initialize(insock, host, port, logfile)
      @insock = insock
      @host = host
      @port = port
      @logfile = logfile
      @outsock = TCPSocket.new(@host, @port) unless $http
      @mutex = Mutex.new if @logfile
      @lastlog = ""
    end

    def log(whoami, buf)
      return unless @logfile
      @mutex.synchronize {
        if (@lastlog != whoami)
          @logfile.print("#{whoami}:\t")
          @lastlog = whoami
        end
        @logfile.print(buf)
        @logfile.flush
      }
    end

    def copy_to_eof(input, output, whoami)
      puts "#{whoami} starting" if $VERBOSE
      begin
        while buf = input.readpartial(8192)
          log(whoami, buf)
          output.syswrite(buf)
        end
      rescue SystemCallError => e
        puts "#{whoami} got #{e.class}, finishing"
      rescue IOError => e
        puts "#{whoami} got IOError, finishing"
      rescue EOFError => e
        # ... and do nothing
        puts "#{whoami} got EOF, finishing" if $VERBOSE
      end
    end

    def copy
      if $http
        # For an http proxy, read the first line and rewrite the request, connecting to the selected host
        line = @insock.readline
        log('REQ', line)
        line =~ %r{^([A-Z]+) http://([^:/]*)(:([0-9]*))?(/[^ ]*) HTTP/([^ ]*)\r\n\Z}
        @method, @host, @port, @path, @http = $1, $2, ($4 || 80).to_i, $5, $6

        log('PROXY', "Connecting to #{@host}:#{@port}\n")
        @outsock = TCPSocket.new(@host, @port)

        rewritten = "#{@method} #{@path} HTTP/#{@http}"
        log('PROXY', "Sending '#{rewritten}'\n")
        @outsock.syswrite(rewritten+"\r\n")
      end
      # Copy the response from the server
      Thread.new { copy_to_eof(@outsock, @insock, 'IN') }

      # Copy the caller's request to the selected host
      copy_to_eof(@insock, @outsock, 'OUT')
    end
  end
end

def Usage(code)
  print \
    "Usage: loggingproxy [ options ... ]\n" \
    "\t--host name\t\tConnect to this computer\n" \
    "\t--port N\t\tConnect to  this port\n" \
    "\t--listen N\t\tAccept connections on this port\n" \
    "\t--base path\t\tBase name for log files\n" \
    "\t--nolog\t\tDon't write any log files\n" \
    "\t--http\t\tAct like an HTTP proxy\n" \
    "\t--verbose\t\tTimings etc\n" \
    "\t--help\t\t\tShow this usage message\n"
  exit(code)
end

$http = nil
$host=""
$port=119
$listen=11119
$base="netlog"
$VERBOSE = false
optionparser = GetoptLong.new
optionparser.set_options(
    ['--host', '-h',        GetoptLong::OPTIONAL_ARGUMENT], # Must have -h & -p, or -H
    ['--port', '-p',        GetoptLong::OPTIONAL_ARGUMENT],
    ['--http', '-H',        GetoptLong::OPTIONAL_ARGUMENT],
    ['--listen', '-l',        GetoptLong::OPTIONAL_ARGUMENT],
    ['--base', '-b',        GetoptLong::OPTIONAL_ARGUMENT],
    ['--nolog', '-n',        GetoptLong::OPTIONAL_ARGUMENT],
    ['--verbose', '-v',      GetoptLong::NO_ARGUMENT],
    ['--help', '-?',        GetoptLong::NO_ARGUMENT])
begin
  optionparser.each_option { |option, value|
    case option
    when '--http'
      $http = true
    when '--host'
      $host = value
    when '--port'
      $port = value.to_i
    when '--listen'
      $listen = value.to_i
    when '--base'
      $base = value
    when '--nolog'
      $nolog = value
    when '--verbose'
      $VERBOSE = true
    when '--help'
      Usage(0)
    else
      Usage(1)
    end
  }
rescue
  Usage(1)  # Error message has been issued
end

Usage(1) if (ARGV.size > 0 || ($host == "" && !$http))
Usage(1) unless $http || $host && $port

server = TCPServer.new('0.0.0.0', $listen)
if $listen == 0
  sockaddr = server.getsockname
  len, family, port, ip = *sockaddr.unpack("ccnN")
  puts "Listening on port #{port}"
end
seq = 0
while (insock = server.accept)
  if ($VERBOSE); print "Connection accepted from"; p insock.addr; end
  logfile = $nolog ? nil : File.new(sprintf("#$base.%03d", seq), 'w')
  seq += 1
  Thread.new do
    n = Net::LoggingProxy.new(insock, $host, $port, logfile)
    n.copy
    insock.close
    puts "Connection closed" if ($VERBOSE) 
  end
end
