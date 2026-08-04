# ── Embedded seticore schema ──────────────────────────────────────────
#
# The schema text is embedded as a string constant so the package is
# self-contained (no external file lookup at runtime). It is parsed in
# `__init__` into the `SETICORE_SCHEMA` Ref, which the rest of the
# package reads via `SETICORE_SCHEMA[]`.

"Embedded seticore Cap'n Proto schema text (parsed once in `__init__`)."
const SETICORE_SCHEMA_TEXT = raw"""@0xb811e7262df2bb01;

struct Signal {
  frequency @0 :Float64;
  index @1 :Int32;
  driftSteps @2 :Int32;
  driftRate @3 :Float64;
  snr @4 :Float32;
  coarseChannel @5 :Int32;
  beam @6 :Int32;
  numTimesteps @7 :Int32;
  power @8 :Float32;
  incoherentPower @9 :Float32;
}

struct Filterbank {
  sourceName @0 :Text;
  fch1 @1 :Float64;
  foff @2 :Float64;
  tstart @3 :Float64;
  tsamp @4 :Float64;
  ra @5 :Float64;
  dec @6 :Float64;
  telescopeId @7 :Int32;
  numTimesteps @8 :Int32;
  numChannels @9 :Int32;
  data @10 :List(Float32);
  coarseChannel @11 :Int32;
  startChannel @12 :Int32;
  beam @13 :Int32;
}

struct Hit {
  signal @0 :Signal;
  filterbank @1 :Filterbank;
}

struct Event {
  hits @0 :List(Hit);
}

struct Stamp {
  seticoreVersion @13 :Text;
  sourceName @0 :Text;
  ra @1 :Float64;
  dec @2 :Float64;
  fch1 @3 :Float64;
  foff @4 :Float64;
  tstart @5 :Float64;
  tsamp @6 :Float64;
  telescopeId @7 :Int32;
  numTimesteps @8 :Int32;
  numChannels @9 :Int32;
  numPolarizations @10 :Int32;
  numAntennas @11 :Int32;
  data @12 :List(Float32);
  coarseChannel @14 :Int32;
  fftSize @15 :Int32;
  startChannel @16 :Int32;
  signal @17 :Signal;
  schan @18 :Int32;
  obsid @19 :Text;
}
"""

"Parsed seticore schema, filled by `__init__`. Read via `SETICORE_SCHEMA[]`."
const SETICORE_SCHEMA = Ref{SchemaFile}()
