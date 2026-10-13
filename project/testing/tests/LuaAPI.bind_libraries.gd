extends UnitTest
var lua: LuaAPI

func _ready():
	# Since we are using poly here, we need to make sure to call super for _methods
	super._ready()
	# id will determine the load order
	id = 9930

	lua = LuaAPI.new()

	# testName and testDescription are for any needed context about the test.
	testName = "LuaAPI.bind_libraries"
	testDescription = "
Binds several libraries and calls a function from each one.
A library is registered under the name passed to bind_libraries, so this fails if
that name is wrong, which is what happens when the name is read from memory that
has already been freed. base is included because it writes into _G directly and
so keeps working even when the name is garbage.
"

func _process(delta):
	# Since we are using poly here, we need to make sure to call super for _methods
	super._process(delta)

	var err = lua.bind_libraries(["base", "math", "string", "table"])
	if err is LuaError:
		errors.append(err)
		status = false
		done = true
		return

	# Each call reaches the library through the global name it was bound under.
	err = lua.do_string("
	floored = math.floor(3.7)
	upper = string.upper('lua')
	joined = table.concat({'a', 'b'}, '-')
	")

	if err is LuaError:
		errors.append(err)
		# Status is true by default, once the test determines a failure state it will set status to false.
		status = false
		done = true
		return

	var checks = {
		"floored": 3,
		"upper": "LUA",
		"joined": "a-b",
	}
	for name in checks:
		var value = lua.pull_variant(name)
		if value != checks[name]:
			errors.append(LuaError.new_error("%s was %s, expected %s" % [name, value, checks[name]]))
			status = false

	# Once done is set to true, the test's _process function will no longer be called.
	done = true
