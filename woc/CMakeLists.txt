# WoC (World of Code) custom tools, built against this libgit2.
#
# These tools enumerate/extract raw git objects from bare repositories.
# Unlike the upstream examples, they rely on libgit2's deprecated aliases
# (GIT_OBJ_*, giterr_last), so we must NOT define GIT_DEPRECATE_HARD here.
# They also use the int-returning check_lg2() from the bundled common.c/.h
# (the upstream examples version returns void).

# NOTE: get_last and batch_fetch are intentionally excluded from the build.
#  - get_last.c calls git_get_last(), a custom function ssc-oscar added inside
#    the old libgit2 fork's library (src/fetch.c); porting it would require
#    modifying this otherwise-stock libgit2.
#  - batch_fetch.c has unfinished code (undeclared packfile_name).
# Their sources are kept in this directory for reference only.
set(WOC_TOOLS
	classify
	compare
	get_new_commits
	init
	list
	grabc
	grabf
	grabft
	grabtag)

foreach(tool ${WOC_TOOLS})
	add_executable(${tool} ${tool}.c common.c)
	# These tools were written for gnu99 (// comments, mixed declarations);
	# libgit2 itself compiles as strict C90, so relax the standard per-target.
	target_compile_options(${tool} PRIVATE -std=gnu99 -Wno-declaration-after-statement)
	target_include_directories(${tool} PRIVATE ${LIBGIT2_INCLUDES} ${LIBGIT2_DEPENDENCY_INCLUDES})
	target_include_directories(${tool} SYSTEM PRIVATE ${LIBGIT2_SYSTEM_INCLUDES})
	if(WIN32 OR ANDROID)
		target_link_libraries(${tool} libgit2package)
	else()
		target_link_libraries(${tool} libgit2package pthread)
	endif()
endforeach()

include(GNUInstallDirs)
install(TARGETS ${WOC_TOOLS} RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# Driver / pipeline scripts (no compilation)
install(PROGRAMS
	grabGitI.perl
	grabGitIType.perl
	fixP.perl
	cleanBlb.perl
	extrCmt.perl
	readPack.perl
	unpack.perl
	doBeaconUpI.sh
	gitListSimp.sh
	gitList.sh
	captureObjects.sh
	captureUpdate.sh
	handleOtherForges.sh
	doA.sh
	doB.sh
	doSkylakeUp1.sh
	startbash.sh
	startDef.sh
	startshell.sh
	DESTINATION ${CMAKE_INSTALL_BINDIR})
