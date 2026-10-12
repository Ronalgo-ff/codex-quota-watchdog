# Original vector-style shield + clock icon; deterministic multi-size ICO.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$sizes=@(16,24,32,48,64,128,256);$frames=@()
foreach($size in $sizes){
    $bmp=New-Object Drawing.Bitmap($size,$size);$g=[Drawing.Graphics]::FromImage($bmp);$g.SmoothingMode='AntiAlias';$g.ScaleTransform($size/256.0,$size/256.0)
    $path=New-Object Drawing.Drawing2D.GraphicsPath;$path.AddArc(8,8,48,48,180,90);$path.AddArc(200,8,48,48,270,90);$path.AddArc(200,200,48,48,0,90);$path.AddArc(8,200,48,48,90,90);$path.CloseFigure()
    $brush=New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Point(0,0)),(New-Object Drawing.Point(256,256)),([Drawing.ColorTranslator]::FromHtml('#132239')),([Drawing.ColorTranslator]::FromHtml('#087F8C')))
    $g.FillPath($brush,$path)
    $shield=New-Object Drawing.Drawing2D.GraphicsPath;$shield.AddLines([Drawing.Point[]]@((New-Object Drawing.Point(128,39)),(New-Object Drawing.Point(207,71)),(New-Object Drawing.Point(201,147)),(New-Object Drawing.Point(173,187)),(New-Object Drawing.Point(128,220)),(New-Object Drawing.Point(83,187)),(New-Object Drawing.Point(55,147)),(New-Object Drawing.Point(49,71))));$shield.CloseFigure()
    $pen=New-Object Drawing.Pen(([Drawing.ColorTranslator]::FromHtml('#83E6E1')),9);$pen.LineJoin='Round';$g.DrawPath($pen,$shield)
    $white=New-Object Drawing.Pen([Drawing.Color]::White,10);$white.StartCap='Round';$white.EndCap='Round';$g.DrawEllipse($white,88,87,80,80);$g.DrawLine($white,128,104,128,129);$g.DrawLine($white,128,129,148,140)
    $g.Dispose();$path.Dispose();$shield.Dispose();$pen.Dispose();$white.Dispose();$brush.Dispose()
    $stream=New-Object IO.MemoryStream;$bmp.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$frames+=,@{size=$size;data=$stream.ToArray()};if($size -eq 256){$bmp.Save((Join-Path $PSScriptRoot 'codex-quota.png'),[Drawing.Imaging.ImageFormat]::Png)};$stream.Dispose();$bmp.Dispose()
}
$file=[IO.File]::Create((Join-Path $PSScriptRoot 'codex-quota.ico'));$writer=New-Object IO.BinaryWriter($file)
try{$writer.Write([int16]0);$writer.Write([int16]1);$writer.Write([int16]$frames.Count);$offset=6+16*$frames.Count
foreach($frame in $frames){$dimension=if($frame.size -eq 256){0}else{$frame.size};$writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([int16]1);$writer.Write([int16]32);$writer.Write([int]$frame.data.Length);$writer.Write([int]$offset);$offset+=$frame.data.Length}
foreach($frame in $frames){$writer.Write([byte[]]$frame.data)}
}finally{$writer.Dispose();$file.Dispose()}
