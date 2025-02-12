#!/usr/bin/env python3
# coding: latin1
import mmap
import struct
import sys

file = 'f.tar'
if len(sys.argv) > 1:
	file = sys.argv[1]
f = open(file, "rb")
data = mmap.mmap(f.fileno(), 0, access = mmap.ACCESS_READ)

matchnum = 0

def mime(type):
	print("MIMETYPE "+type)

def match(msg, mime='', dbg=''):
	global matchnum
	matchnum += 1
	print("MATCH "+dbg)
	if msg:
		print("DISPLAY: "+msg)

def unpack(off, fmt):
	global data
	size = struct.calcsize(fmt)
	val = data[off:off+size]
	ret = struct.unpack(fmt, val)
	return ret[0]

def string(off, size):
	global data
	val = data[off:off+size]
	return val.decode('latin1')

def nomatch(dbg=''):
	global matchnum
	if matchnum == 0:
		print("no matches, exec default "+dbg)
		return True
	matchnum = 0
	print("matches, return false "+dbg)
	return False

def clear(dbg=''):
	global matchnum
	matchnum = 0
	return True

def missing(d='',t=''):
	print("Not implemented: "+d+"("+t+")")
	return True

def display(fmt, mime, val, dbg=''):
	if type(val) == str:
		val = val.split('\x00', 1)[0]
	if val:
		if '%c' in fmt:
			val = val % 256
		out = fmt % val
		print("DISPLAY: "+out+" "+dbg)
		#print("DISPLAY2: "+val.encode().hex())

def use(name, flip):
	print("we *should* now call "+name)

