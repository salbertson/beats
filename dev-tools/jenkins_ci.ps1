function Exec
{
    param(
        [Parameter(Position=0,Mandatory=1)][scriptblock]$cmd,
        [Parameter(Position=1,Mandatory=0)][string]$errorMessage = ($msgs.error_bad_command -f $cmd)
    )

    & $cmd
    if ($LastExitCode -ne 0) {
        Write-Error $errorMessage
        exit $LastExitCode
    }
}

# Setup Go.
$env:GOPATH = $env:WORKSPACE
$env:PATH = "$env:GOPATH\bin;C:\tools\mingw64\bin;$env:PATH"
& gvm --format=powershell $(Get-Content .go-version) | Invoke-Expression

# Write cached magefile binaries to workspace to ensure
# each run starts from a clean slate.
$env:MAGEFILE_CACHE = "$env:WORKSPACE\.magefile"

exec { go install github.com/elastic/beats/vendor/github.com/magefile/mage }

echo "Fetching testing dependencies"
# TODO (elastic/beats#5050): Use a vendored copy of this.
exec { go get github.com/docker/libcompose }
exec { go get github.com/jstemmer/go-junit-report }

echo "Building libbeat fields.yml"
cd libbeat
exec { mage fields }
cd ..

if (Test-Path "$env:beat") {
    cd "$env:beat"
} else {
    echo "$env:beat does not exist"
    New-Item -ItemType directory -Path build | Out-Null
    New-Item -Name build\TEST-empty.xml -ItemType File | Out-Null
    exit
}

if (Test-Path "build") { Remove-Item -Recurse -Force build }
New-Item -ItemType directory -Path build\coverage | Out-Null
New-Item -ItemType directory -Path build\system-tests | Out-Null
New-Item -ItemType directory -Path build\system-tests\run | Out-Null

echo "Building fields.yml"
exec { mage fields }

echo "Building $env:beat"
exec { mage build } "Build FAILURE"

echo "Unit testing $env:beat"
go test -v $(go list ./... | select-string -Pattern "vendor" -NotMatch) 2>&1 | Out-File -encoding UTF8 build/TEST-go-unit.out
exec { Get-Content build/TEST-go-unit.out | go-junit-report.exe -set-exit-code | Out-File -encoding UTF8 build/TEST-go-unit.xml } "Unit test FAILURE"

echo "System testing $env:beat"
# Get a CSV list of package names.
$packages = $(go list ./... | select-string -Pattern "/vendor/" -NotMatch | select-string -Pattern "/scripts/cmd/" -NotMatch)
$packages = ($packages|group|Select -ExpandProperty Name) -join ","
exec { go test -race -c -cover -covermode=atomic -coverpkg $packages }
exec { cd tests/system }
exec { nosetests --with-timer --with-xunit --xunit-file=../../build/TEST-system.xml } "System test FAILURE"
