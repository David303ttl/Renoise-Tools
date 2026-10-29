#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$OutputPath = (Join-Path $PSScriptRoot 'fixtures\host_lifecycle_cases.json')
)

$ErrorActionPreference = 'Stop'

function New-HostLifecycleCase {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$TriggerMode,
    [Parameter(Mandatory)][object[]]$Events,
    [Parameter(Mandatory)][double[]]$OnsetSteps,
    [Parameter(Mandatory)][double]$FinalOffStep
  )
  $onsets = @($OnsetSteps | ForEach-Object {
    @{ at_step = $_; note = 48; tolerance_ms = 5 }
  })
  $pitchWindows = @($OnsetSteps | ForEach-Object {
    @{ start_step = $_ + 0.32; end_step = $_ + 0.72; note = 48 }
  })
  $silenceStart = $FinalOffStep + 0.08
  $silenceEnd = $FinalOffStep + 0.28
  return [ordered]@{
    id = $Id
    status = 'ready'
    trigger = 'native_host_pattern_events'
    purpose = 'native-host-lifecycle'
    profile = @{
      id = 'acid-reference-168-frame-saw'
      root_note = 48
      sample_rate = 44100
      sample_frames = 168
      base_frequency_hz = 262.5
      envelope = 'attack 10 ms, decay 20 ms to 0.65 sustain, release 5 ms'
    }
    capture = @{
      sample_rate = 48000
      sample_format = 'PCM24'
      channels = 'mono-or-dual-mono-stereo'
      bpm = 120
      song_lpb = 8
      tpl = 12
      minimum_tail_ms = 500
    }
    playback = @{
      renderer = 'native-host-lifecycle-pattern'
      trigger_mode = $TriggerMode
      phrase_lpb = 8
      lines_per_step = 2
      cold_cycles = 1
      steady_cycles = 0
      looping = $false
    }
    protocol = @{
      origin_step = 0
      silent_preroll_steps = 16
      host_events = @($Events)
      pitch = 48
      final_host_off_step = $FinalOffStep
      host_release_deadline_ms = 10
    }
    source = @{
      length = 2
      time = @('N', 'R')
      pitches = @(48)
      pitch_length = 1
      accent_pitch_indices = @()
      slide_pitch_indices = @()
    }
    expected = @{
      onsets = $onsets
      pitch_windows = $pitchWindows
      silence_windows = @(@{ start_step = $silenceStart; end_step = $silenceEnd })
      release_edges = @(@{
        off_at_step = $FinalOffStep
        silence_starts_at_step = $silenceStart
        maximum_tail_ms = 10
        confirmation_ms = 8
      })
    }
    analysis = @{
      onset_floor_dbfs = -60
      onset_tolerance_ms = 5
      pitch_tolerance_cents = 15
      minimum_pitch_window_ms = 40
      maximum_continuity_dip_ms = 4
      maximum_continuity_dip_db = 6
      onset_refractory_ms = 40
      onset_window_ms = 10
      silence_dbfs = -60
    }
    qualification = @{
      protocol_status = 'ready'
      acoustic_status = 'unverified'
      blockers = @('A matching native capture is required; synthetic analyzer controls do not establish Renoise playback.')
    }
  }
}

$hostOffEvents = @(
  @{ event = 'NOTE'; note = 48; at_step = 0; pattern_line = 33 },
  @{ event = 'OFF'; at_step = 8; pattern_line = 49 }
)
$retriggerEvents = @(
  @{ event = 'NOTE'; note = 48; at_step = 0; pattern_line = 33 },
  @{ event = 'NOTE'; note = 48; at_step = 8; pattern_line = 49 },
  @{ event = 'OFF'; at_step = 16; pattern_line = 65 }
)
$cases = @(
  (New-HostLifecycleCase -Id 'host_note_off_native' -TriggerMode selective -Events $hostOffEvents -OnsetSteps @(0) -FinalOffStep 8),
  (New-HostLifecycleCase -Id 'fresh_retrigger_native' -TriggerMode selective -Events $retriggerEvents -OnsetSteps @(0, 8) -FinalOffStep 16),
  (New-HostLifecycleCase -Id 'keymapped_trigger_native' -TriggerMode keymapped -Events $hostOffEvents -OnsetSteps @(0) -FinalOffStep 8)
)
$fixture = [ordered]@{
  format = 'ACID-AUDIO-ORACLE-1'
  status = 'Independent native host lifecycle windows at 120 BPM; event times are authored from song-pattern line positions. Acoustic status remains unverified.'
  index_base = 0
  step_unit = 'one straight TIME sixteenth; one step = four phrase lines at phrase LPB 16'
  capture_requirements = @{
    sample_rate = 48000
    preferred_channels = 1
    allowed_channels = @(1, 2)
    preferred_pcm_bits = 24
    allowed_pcm_bits = @(16, 24, 32)
    peak_ceiling_dbfs = -6
    align_once_to_first_onset = $true
    no_per_cycle_realign = $true
  }
  profile = @{
    id = 'acid-reference-168-frame-saw'
    sample_rate = 44100
    sample_fundamental_hz = 262.5
    sample_frames = 168
    root_note = 48
    sample_peak_linear = 0.35
    sample_volume = 3.0
    envelope = @{ attack_ms = 10; decay_ms = 20; sustain = 0.65; release_ms = 5 }
    loop = 'forward whole cycle'
    interpolation = 'linear'
  }
  analysis_defaults = @{
    silence_rms_dbfs = -60
    onset_tolerance_ms = 5
    release_tail_tolerance_ms = 5
    continuity_max_dip_duration_ms = 4
    pitch_tolerance_cents = 15
    continuity_max_dip_db = 6
    pitch_window_minimum_ms = 40
    onset_refractory_ms = 40
  }
  cases = $cases
}

$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output "Wrote $($cases.Count) analyzer-ready native lifecycle protocols to $OutputPath. Acoustic status remains unverified."
