# schemas/v1/lib/schema-check.jq
#
# Bounded JSON Schema 2020-12 subset evaluator used by schemas/v1/validate.sh.
# It makes the four versioned schemas the single source of truth for fixture
# validation with jq alone (no network, no extra runtime).
#
# Supported keywords: $ref (local "#/$defs/...", used alone, no siblings),
# type, enum, const, minLength, maxLength, pattern, minimum, maximum, minItems,
# maxItems, uniqueItems, items, contains, required, properties,
# additionalProperties (false or a schema), propertyNames, minProperties,
# maxProperties, allOf, anyOf, oneOf, not, if/then/else.
#
# Fail closed: any other keyword is an error, never ignored silently, so a
# constraint added to a schema can not be validated away by this evaluator.
#
# Invocation: jq -e --slurpfile schema <schema.json> -f schema-check.jq <instance.json>
# Input: one JSON instance document. The schema arrives in $schema.
# Output: true when the instance is valid, false otherwise.

def supported_keywords: [
  "$ref", "$defs", "$schema", "$id", "$comment", "title", "description",
  "default", "examples", "deprecated", "readOnly", "writeOnly",
  "type", "enum", "const", "minLength", "maxLength", "pattern",
  "minimum", "maximum", "minItems", "maxItems", "uniqueItems", "items",
  "contains", "required", "properties", "additionalProperties",
  "propertyNames", "minProperties", "maxProperties", "allOf", "anyOf",
  "oneOf", "not", "if", "then", "else"
];

def check($s; $i; $root):
  def unknown: $s | keys_unsorted | map(select(. as $k | supported_keywords | index($k) | not));
  if ($s | type) != "object" then
    true
  elif (unknown | length) > 0 then
    error("unsupported schema keyword(s): \(unknown | join(", "))")
  elif ($s | has("$ref")) then
    ($s["$ref"]
      | ltrimstr("#/")
      | split("/")
      | map(gsub("~1"; "/") | gsub("~0"; "~"))) as $path
    | check($root | getpath($path); $i; $root)
  else
    ([
      (if ($s | has("type")) then
         ($s.type | if type == "string" then [.] else . end) as $types
         | any($types[];
             (. == "object"  and ($i | type) == "object")
             or (. == "array"   and ($i | type) == "array")
             or (. == "string"  and ($i | type) == "string")
             or (. == "number"  and ($i | type) == "number")
             or (. == "integer" and ($i | type) == "number" and $i == ($i | floor))
             or (. == "boolean" and ($i | type) == "boolean")
             or (. == "null"    and $i == null))
       else true end),

      (if ($s | has("enum")) then ($s.enum | index($i)) != null else true end),
      (if ($s | has("const")) then $i == $s.const else true end),

      (if ($s | has("minLength")) and ($i | type) == "string"
         then ($i | length) >= $s.minLength else true end),
      (if ($s | has("maxLength")) and ($i | type) == "string"
         then ($i | length) <= $s.maxLength else true end),
      (if ($s | has("pattern")) and ($i | type) == "string"
         then $i | test($s.pattern) else true end),

      (if ($s | has("minimum")) and ($i | type) == "number"
         then $i >= $s.minimum else true end),
      (if ($s | has("maximum")) and ($i | type) == "number"
         then $i <= $s.maximum else true end),

      (if ($s | has("minItems")) and ($i | type) == "array"
         then ($i | length) >= $s.minItems else true end),
      (if ($s | has("maxItems")) and ($i | type) == "array"
         then ($i | length) <= $s.maxItems else true end),
      (if ($s | has("minProperties")) and ($i | type) == "object"
         then ($i | length) >= $s.minProperties else true end),
      (if ($s | has("maxProperties")) and ($i | type) == "object"
         then ($i | length) <= $s.maxProperties else true end),
      (if ($s | has("uniqueItems")) and $s.uniqueItems == true and ($i | type) == "array"
         then ($i | length) == ($i | unique | length) else true end),
      (if ($s | has("items")) and ($i | type) == "array"
         then all($i[]; check($s.items; .; $root)) else true end),
      (if ($s | has("contains")) and ($i | type) == "array"
         then any($i[]; check($s.contains; .; $root)) else true end),

      (if ($s | has("required")) and ($i | type) == "object"
         then all($s.required[]; . as $name | $i | has($name)) else true end),
      (if ($s | has("properties")) and ($i | type) == "object"
         then all($s.properties | to_entries[];
                .key as $name
                | if ($i | has($name)) then check(.value; $i[$name]; $root) else true end)
       else true end),
      (if ($s | has("additionalProperties")) and ($i | type) == "object"
         then (($s.properties // {}) | keys) as $known
         | all($i | keys[];
             . as $name
             | if ($known | index($name)) != null then true
               elif $s.additionalProperties == false then false
               elif ($s.additionalProperties | type) == "object"
                 then check($s.additionalProperties; $i[$name]; $root)
               else true end)
       else true end),
      (if ($s | has("propertyNames")) and ($i | type) == "object"
         then all($i | keys[]; check($s.propertyNames; .; $root)) else true end),

      (if ($s | has("allOf")) then all($s.allOf[]; check(.; $i; $root)) else true end),
      (if ($s | has("anyOf")) then any($s.anyOf[]; check(.; $i; $root)) else true end),
      (if ($s | has("oneOf"))
         then ([$s.oneOf[] | check(.; $i; $root)] | map(select(.)) | length) == 1
       else true end),
      (if ($s | has("not")) then (check($s["not"]; $i; $root) | not) else true end),
      (if ($s | has("if")) then
         (if check($s["if"]; $i; $root) then
            (if ($s | has("then")) then check($s["then"]; $i; $root) else true end)
          else
            (if ($s | has("else")) then check($s["else"]; $i; $root) else true end)
          end)
       else true end)
    ] | all(.[]; .))
  end;

check($schema[0]; .; $schema[0])
