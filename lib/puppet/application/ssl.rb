require 'puppet/application'
require 'puppet/ssl/oids'

class Puppet::Application::Ssl < Puppet::Application

  run_mode :agent

  def summary
    _("Manage SSL keys and certificates for puppet SSL clients")
  end

  def help
    <<-HELP
puppet-ssl(8) -- #{summary}
========

SYNOPSIS
--------
Manage SSL keys and certificates for SSL clients needing
to communicate with a puppet infrastructure.

USAGE
-----
puppet ssl <action> [-h|--help] [-v|--verbose] [-d|--debug] [--localca] [--target CERTNAME]


OPTIONS
-------

* --help:
  Print this help messsge.

* --verbose:
  Print extra information.

* --debug:
  Enable full debugging.

* --localca
  Also clean the local CA certificate and CRL.

* --target CERTNAME
  Clean the specified device certificate instead of this host's certificate.

ACTIONS
-------

* bootstrap:
  Perform all of the steps necessary to request and download a client
  certificate. If autosigning is disabled, then puppet will wait every
  `waitforcert` seconds for its certificate to be signed. To only attempt
  once and never wait, specify a time of 0. Since `waitforcert` is a
  Puppet setting, it can be specified as a time interval, such as 30s,
  5m, 1h.

* submit_request:
  Generate a certificate signing request (CSR) and submit it to the CA. If
  a private and public key pair already exist, they will be used to generate
  the CSR. Otherwise a new key pair will be generated. If a CSR has already
  been submitted with the given `certname`, then the operation will fail.

* download_cert:
  Download a certificate for this host. If the current private key matches
  the downloaded certificate, then the certificate will be saved and used
  for subsequent requests. If there is already an existing certificate, it
  will be overwritten.

* verify:
  Verify the private key and certificate are present and match, verify the
  certificate is issued by a trusted CA, and check revocation status.

* clean:
  Remove the private key and certificate related files for this host. If
  `--localca` is specified, then also remove this host's local copy of the
  CA certificate(s) and CRL bundle. if `--target CERTNAME` is specified, then
  remove the files for the specified device on this host instead of this host.
HELP
  end

  option('--target CERTNAME') do |arg|
    options[:target] = arg.to_s
  end
  option('--localca')
  option('--verbose', '-v')
  option('--debug', '-d')

  def initialize(command_line = Puppet::Util::CommandLine.new)
    super(command_line)

    @cert_provider = Puppet::X509::CertProvider.new
    @ssl_provider = Puppet::SSL::SSLProvider.new
    @machine = Puppet::SSL::StateMachine.new
  end

  def setup_logs
    set_log_level(options)
    Puppet::Util::Log.newdestination(:console)
  end

  def main
    if command_line.args.empty?
      raise Puppet::Error, _("An action must be specified.")
    end

    if options[:target]
      # Override the following, as per lib/puppet/application/device.rb
      Puppet[:certname] = options[:target]
      Puppet[:confdir]  = File.join(Puppet[:devicedir], Puppet[:certname])
      Puppet[:vardir]   = File.join(Puppet[:devicedir], Puppet[:certname])
      Puppet.settings.use(:main, :agent, :device)
    else
      Puppet.settings.use(:main, :agent)
    end

    Puppet::SSL::Oids.register_puppet_oids

    certname = Puppet[:certname]
    action = command_line.args.first
    case action
    when 'submit_request'
      ssl_context = @machine.ensure_ca_certificates
      if submit_request(ssl_context)
        cert = download_cert(ssl_context)
        unless cert
          Puppet.info(_("The certificate for '%{name}' has not yet been signed") % { name: certname })
        end
      end
    when 'download_cert'
      ssl_context = @machine.ensure_ca_certificates
      cert = download_cert(ssl_context)
      unless cert
        raise Puppet::Error, _("The certificate for '%{name}' has not yet been signed") % { name: certname }
      end
    when 'verify'
      verify(certname)
    when 'clean'
      clean(certname)
    when 'bootstrap'
      if !Puppet::Util::Log.sendlevel?(:info)
        Puppet::Util::Log.level = :info
      end
      @machine.ensure_client_certificate
      Puppet.notice(_("Completed SSL initialization"))
    else
      raise Puppet::Error, _("Unknown action '%{action}'") % { action: action }
    end
  end

  def submit_request(ssl_context)
    key = @cert_provider.load_private_key(Puppet[:certname])
    unless key
      Puppet.info _("Creating a new SSL key for %{name}") % { name: Puppet[:certname] }
      key = OpenSSL::PKey::RSA.new(Puppet[:keylength].to_i)
      @cert_provider.save_private_key(Puppet[:certname], key)
    end

    csr = @cert_provider.create_request(Puppet[:certname], key)
    Puppet::Rest::Routes.put_certificate_request(csr.to_pem, Puppet[:certname], ssl_context)
    @cert_provider.save_request(Puppet[:certname], csr)
    Puppet.notice _("Submitted certificate request for '%{name}' to https://%{server}:%{port}") % {
      name: Puppet[:certname], server: Puppet[:ca_server], port: Puppet[:ca_port]
    }
  rescue Puppet::Rest::ResponseError => e
    if e.response.code.to_i == 400
      raise Puppet::Error.new(_("Could not submit certificate request for '%{name}' to https://%{server}:%{port} due to a conflict on the server") % { name: Puppet[:certname], server: Puppet[:ca_server], port: Puppet[:ca_port] })
    else
      raise Puppet::Error.new(_("Failed to submit certificate request: %{message}") % { message: e.message }, e)
    end
  rescue => e
    raise Puppet::Error.new(_("Failed to submit certificate request: %{message}") % { message: e.message }, e)
  end

  def download_cert(ssl_context)
    key = @cert_provider.load_private_key(Puppet[:certname])

    Puppet.info _("Downloading certificate '%{name}' from https://%{server}:%{port}") % {
      name: Puppet[:certname], server: Puppet[:ca_server], port: Puppet[:ca_port]
    }

    # try to download cert
    x509 = Puppet::Rest::Routes.get_certificate(Puppet[:certname], ssl_context)
    cert = OpenSSL::X509::Certificate.new(x509)
    Puppet.notice _("Downloaded certificate '%{name}' with fingerprint %{fingerprint}") % { name: Puppet[:certname], fingerprint: fingerprint(cert) }
    # verify client cert before saving
    @ssl_provider.create_context(
      cacerts: ssl_context.cacerts, crls: ssl_context.crls, private_key: key, client_cert: cert
    )
    @cert_provider.save_client_cert(Puppet[:certname], cert)
    @cert_provider.delete_request(Puppet[:certname])

    Puppet.notice _("Downloaded certificate '%{name}' with fingerprint %{fingerprint}") % {
      name: Puppet[:certname], fingerprint: fingerprint(cert)
    }
    cert
  rescue Puppet::Rest::ResponseError => e
    if e.response.code.to_i == 404
      return nil
    else
      raise Puppet::Error.new(_("Failed to download certificate: %{message}") % { message: e.message }, e)
    end
  rescue => e
    raise Puppet::Error.new(_("Failed to download certificate: %{message}") % { message: e.message }, e)
  end

  def verify(certname)
    ssl_context = @ssl_provider.load_context(certname: certname)

    # print from root to client
    ssl_context.client_chain.reverse.each_with_index do |cert, i|
      digest = Puppet::SSL::Digest.new('SHA256', cert.to_der)
      if i == ssl_context.client_chain.length - 1
        Puppet.notice("Verified client certificate '#{cert.subject.to_utf8}' fingerprint #{digest}")
      else
        Puppet.notice("Verified CA certificate '#{cert.subject.to_utf8}' fingerprint #{digest}")
      end
    end
  end

  def clean(certname)
    # make sure cert has been removed from the CA
    if certname == Puppet[:ca_server]
      cert = nil

      begin
        ssl_context = @machine.ensure_ca_certificates
        cert = Puppet::Rest::Routes.get_certificate(certname, ssl_context)
      rescue Puppet::Rest::ResponseError => e
        if e.response.code.to_i != 404
          raise Puppet::Error.new(_("Failed to connect to the CA to determine if certificate %{certname} has been cleaned") % { certname: certname }, e)
        end
      rescue => e
        raise Puppet::Error.new(_("Failed to connect to the CA to determine if certificate %{certname} has been cleaned") % { certname: certname }, e)
      end

      if cert
        raise Puppet::Error, _(<<END) % { certname: certname }
The certificate %{certname} must be cleaned from the CA first. To fix this,
run the following commands on the CA:
  puppetserver ca clean --certname %{certname}
  puppet ssl clean
END
      end
    end

    paths = {
      'private key' => Puppet[:hostprivkey],
      'public key'  => Puppet[:hostpubkey],
      'certificate request' => File.join(Puppet[:requestdir], "#{Puppet[:certname]}.pem"),
      'certificate' => Puppet[:hostcert],
      'private key password file' => Puppet[:passfile]
    }
    paths.merge!('local CA certificate' => Puppet[:localcacert], 'local CRL' => Puppet[:hostcrl]) if options[:localca]
    paths.each_pair do |label, path|
      if Puppet::FileSystem.exist?(path)
        Puppet::FileSystem.unlink(path)
        Puppet.notice _("Removed %{label} %{path}") % { label: label, path: path }
      end
    end
  end

  private

  def fingerprint(cert)
    Puppet::SSL::Digest.new(nil, cert.to_der)
  end
end
