# ===----------------------------------------------------------------------=== #
# Key codes.
#
# These are MAC virtual key codes, and that is not an accident to be tidied
# away silently: `window.mojo`'s `_mac_code` maps Windows VKs onto them so
# that the pane's key surface is the one the Metal original had. It is the
# right call while the two backends are meant to agree, and it is the wrong
# shape for a portable API to expose -- a Windows game asking for key 53
# reads as a magic number. The portable tier above this is where that gets
# a name; until it exists, these are the names.
# ===----------------------------------------------------------------------=== #

comptime KEY_LEFT = 123
comptime KEY_RIGHT = 124
comptime KEY_DOWN = 125
comptime KEY_UP = 126
comptime KEY_SPACE = 49
comptime KEY_ESCAPE = 53
comptime KEY_RETURN = 36
comptime KEY_1 = 18
comptime KEY_2 = 19
comptime KEY_3 = 20
comptime KEY_4 = 21
comptime KEY_A = 0
comptime KEY_S = 1
comptime KEY_D = 2
comptime KEY_W = 13
comptime KEY_Z = 6
comptime KEY_X = 7
