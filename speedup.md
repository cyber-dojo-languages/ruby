# Where the ruby start-point time goes

An investigation into whether the ruby start-points have the same kind of
headroom the JVM ones had, where an AOT cache took the class-loading off every
test-run. They do, and it is the same shape: ruby parses and compiles the whole
test framework from source on every single test-run, and that can be done once
at image build instead.

This covers the five start-points built on this image:

    ruby-approval    ghcr.io/cyber-dojo-languages/ruby_approval:6084b46
    ruby-cucumber    ghcr.io/cyber-dojo-languages/ruby_cucumber:2c18d33
    ruby-minitest    ghcr.io/cyber-dojo-languages/ruby_mini_test:da2b0dd
    ruby-rspec       ghcr.io/cyber-dojo-languages/ruby_rspec:961d9ee
    ruby-testunit    ghcr.io/cyber-dojo-languages/ruby_test_unit:f961a02

Nothing here has been implemented. It is a set of measurements and one
proposal.


## Measurement conditions

arm64 host, Docker Desktop. The images are arm64 native, so nothing is
emulated: `ruby -v` inside them reports

    ruby 4.0.1 (2026-01-13 revision e04267a14b) +PRISM [aarch64-linux-musl]

Production is amd64 on Linux, so treat the ratios here as portable and the
absolute numbers as not.

Every figure is the median of 5 runs of the start-point's own shipped
`cyber-dojo.sh`, run the way runner's `home_files.rb` runs it: as user
`sandbox`, with `HOME=/home/sandbox`, with `CYBER_DOJO_SANDBOX` set, with the
fs-cleaners written to the sandbox home, and with `manifest.json` and
`red_amber_green.rb` held out of the sandbox because runner does not put them
there. Each run produced the correct traffic-light, which is what makes the
timings comparable.

Run-to-run spread is a few milliseconds, so differences below about 5ms in
these tables are not meaningful.


## What a test-run pays today

The body is one run of `cyber-dojo.sh`. It excludes the container lifecycle,
which `runner/docs/profiling/where-the-traffic-light-time-goes.txt` measures
separately at about 114ms.

    start-point      body ms
    minitest              56
    testunit              74
    rspec                 90
    approval             106
    cucumber             139

The tests themselves are not in these numbers in any meaningful sense.
Minitest reports `Finished in 0.000509s` for its two examples. Essentially all
of the body is getting ruby to the point where it can run them.


## Finding: the body is parsing the framework, not running the tests

Ruby's own startup is not the problem. In the minitest image:

    ruby -e ''                                       22 ms
    ruby --disable-gems -e ''                         5 ms
    require simplecov, simplecov-console, minitest   49 ms

A bare interpreter is 22ms. Loading what the start-point needs more than
doubles it. That load pulls in 137 files against 10 for a bare
`--disable-gems` interpreter.

Splitting the body by removing one thing at a time, each line differing from
`full` in exactly one respect:

    variant       minitest    rspec   cucumber
    full             54 ms    86 ms     135 ms
    no simplecov     36 ms    67 ms     121 ms
    no did_you_mean
      + no error_
      highlight      49 ms    78 ms     124 ms
    neither          33 ms    61 ms     108 ms

`no simplecov` empties `coverage.rb` so the gem is never loaded.
`no did_you_mean + no error_highlight` passes
`--disable-did_you_mean --disable-error_highlight` in RUBYOPT.

So on a typical start-point, roughly a third of the body is loading code that
is identical on every test-run of every kata in that image.

Measuring that directly, over exactly the files a real run loads, by comparing
`RubyVM::InstructionSequence.compile_file` against
`RubyVM::InstructionSequence.load_from_binary` of the same code:

    start-point   files   parse+compile   load binary   difference   cache KB
    minitest        129         30.5 ms        4.8 ms      25.7 ms        993
    rspec           167         40.4 ms        7.9 ms      32.5 ms       1336
    cucumber        474         83.2 ms       12.8 ms      70.4 ms       2598

That difference is the ceiling on what a compile cache can take off, and it is
most of the body.


## Finding: an instruction-sequence cache takes 26 to 32 per cent off every ruby LTF

Ruby has the hook for this built in, and it is what bootsnap uses. Whenever
ruby is about to compile a file it calls
`RubyVM::InstructionSequence.load_iseq(path)`, and uses whatever ISeq comes
back. Returning nil compiles the source as usual.

So the whole runtime half is about fifteen lines:

```ruby
# Serves ruby's compiler from a cache of already-compiled instruction
# sequences, so a require reads bytecode instead of parsing source.
# Loaded via RUBYOPT=-r so the hook is in place before the start-point's
# own requires run. The cache is read-only at run time.

module IseqCache
  DIR = ENV.fetch('ISEQ_CACHE_DIR')

  def self.cache_path(source_path)
    File.join(DIR, "#{source_path.tr('/', '%')}.yarb")
  end
end

def (RubyVM::InstructionSequence).load_iseq(source_path)
  cached = IseqCache.cache_path(source_path)
  return nil unless File.exist?(cached)

  RubyVM::InstructionSequence.load_from_binary(File.binread(cached))
rescue StandardError
  nil
end
```

The build half walks `Gem::Specification.map(&:full_require_paths)` plus
`$LOAD_PATH`, compiles every `.rb` under them, and writes each one's
`to_binary` into the cache dir. That is the step `install.sh` would gain.

Running each of the five shipped `cyber-dojo.sh` files with and without it:

    start-point    today    cached   saving
    minitest        53 ms    39 ms     -26%
    testunit        78 ms    53 ms     -32%
    rspec           91 ms    62 ms     -32%
    approval        98 ms    71 ms     -28%
    cucumber       128 ms    90 ms     -30%

All five produced the same traffic-light cached as uncached.

What it costs, per image:

    start-point    files cached   cache size   build time
    minitest              1642        16 MB       0.89 s
    testunit              1642        16 MB       0.77 s
    rspec                 1854        18 MB       0.83 s
    approval              2089        19 MB       0.89 s
    cucumber              2843        22 MB       1.09 s

So about a second of build and 16 to 22MB of image, against 14 to 38ms off
every test-run for as long as the image is deployed. The cache is built from
files that are already in the image, so it compiles nothing that a test-run
would not have compiled anyway.

Three properties worth stating, because they are what make it safe:

The cache must cover only the gem and ruby lib dirs, never the sandbox. The
hook keys purely on path. A kata file that had been cached would keep running
its build-time bytecode however the learner edited it, which is a wrong
traffic-light rather than a slow one. Nothing under `CYBER_DOJO_SANDBOX` exists
at image build, so the build cannot cache one by accident, but the build must
not be widened to a bare filesystem walk either.

A miss is free and a corrupt entry is free. `File.exist?` false returns nil,
and the rescue turns any failure to read or parse an entry back into nil, which
is the normal compile path. The cache can therefore only make a test-run
slower, never wrong.

ISeq binaries are specific to the ruby version and platform that wrote them.
Here the writer and the reader are the same ruby in the same image, fixed at
build time, so the constraint is satisfied by construction. It does mean the
cache has to be rebuilt in the same build step as any ruby upgrade, not copied
forward.


## Finding: SimpleCov is paid on every run and reports only on green

`coverage.rb` costs 14 to 19ms of the body, on every test-run. It produces a
report only when the traffic-light is green. Every red run in these
measurements printed

    Stopped processing SimpleCov as a previous error not related to
    SimpleCov has been detected

which is SimpleCov declining to write the report. Under TDD, red is the common
case, so most test-runs pay the full load cost for nothing.

`coverage.rb` already says as much in its own comment: it wants to write the
report only on green and notes there seems to be no way to know. Whether the
cost can be made conditional is an open question and is not answered here. It
is a design question about what the learner should see, not only a performance
one, so it needs deciding rather than measuring.

Note the ISeq cache reduces this cost rather than removing it: loading
SimpleCov is mostly parsing SimpleCov.


## Smaller levers

Disabling the default gems `did_you_mean` and `error_highlight` through RUBYOPT
is worth 5 to 11ms, from the table above. Both change what a learner sees when
their code raises, so this is a visible-behaviour change, not a free one.

Running `ruby --disable-gems` with a `RUBYLIB` baked from
`Gem::Specification.map(&:full_require_paths)` takes the
simplecov + simplecov-console + minitest load from 44ms to 33ms, and the
requires still resolve. It does not generalise: rspec and cucumber are launched
through gem binstubs, which need rubygems to find their executable, so this
would only ever apply to the two start-points that invoke `ruby` directly.


## Not measured

Whether the smaller levers stack with the ISeq cache or are the same parse cost
counted twice. Expect substantial overlap, since all three attack load time,
but that is a prediction and not a measurement.

The amd64 numbers. Everything here is arm64.

The effect of the cache on image pull time. It adds 16 to 22MB to a layer, and
the pull is off the test-run path but not off the deployment path.


## Reproducing

The probes were written for this investigation and are not committed anywhere.
They are small enough to restate: mount a start-point's `start_point` dir into
its language image, set up the sandbox exactly as `home_files.rb` does, and
time `bash ./cyber-dojo.sh` as user `sandbox`. Getting `CYBER_DOJO_SANDBOX` and
`HOME` right matters, because without them the script aborts on its first line
in about a millisecond and reads as very fast rather than as broken.
