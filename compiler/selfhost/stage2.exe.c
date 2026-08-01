#include "runtime.h"

OrbitArena* arena = NULL;

#ifndef AST_VARIANTS_DEFINED
#define AST_VARIANTS_DEFINED
#define Program(x) ((void*)(uintptr_t)(x))
#define FunctionDecl(x) ((void*)(uintptr_t)(x))
#define RouteDecl(x) ((void*)(uintptr_t)(x))
#define ModelDecl(x) ((void*)(uintptr_t)(x))
#define TypeDecl(x) ((void*)(uintptr_t)(x))
#define FieldDecl(x) ((void*)(uintptr_t)(x))
#define TraitDecl(x) ((void*)(uintptr_t)(x))
#define ImplDecl(x) ((void*)(uintptr_t)(x))
#define VarDecl(x) ((void*)(uintptr_t)(x))
#define ConstDecl(x) ((void*)(uintptr_t)(x))
#define ScheduleDecl(x) ((void*)(uintptr_t)(x))
#define ConfigDecl(x) ((void*)(uintptr_t)(x))
#define ImportStmt(x) ((void*)(uintptr_t)(x))
#define UseStmt(x) ((void*)(uintptr_t)(x))
#define ExpressionStmt(x) ((void*)(uintptr_t)(x))
#define If(x) ((void*)(uintptr_t)(x))
#define While(x) ((void*)(uintptr_t)(x))
#define For(x) ((void*)(uintptr_t)(x))
#define Return(x) ((void*)(uintptr_t)(x))
#define Match(x) ((void*)(uintptr_t)(x))
#define MatchCase(x) ((void*)(uintptr_t)(x))
#define Try(x) ((void*)(uintptr_t)(x))
#define Literal(x) ((void*)(uintptr_t)(x))
#define BinaryOp(x) ((void*)(uintptr_t)(x))
#define UnaryOp(x) ((void*)(uintptr_t)(x))
#define Call(x) ((void*)(uintptr_t)(x))
#define MemberAccess(x) ((void*)(uintptr_t)(x))
#define IndexAccess(x) ((void*)(uintptr_t)(x))
#define ListLiteral(x) ((void*)(uintptr_t)(x))
#define Assignment(x) ((void*)(uintptr_t)(x))
#define TypeAnnotation(x) ((void*)(uintptr_t)(x))
#define GenericParam(x) ((void*)(uintptr_t)(x))
#define Decorator(x) ((void*)(uintptr_t)(x))
#define Block(x) ((void*)(uintptr_t)(x))
#define Break(...) ((void*)0)
#define Continue(...) ((void*)0)
#define Param(x) ((void*)(uintptr_t)(x))
#define FieldInit(x) ((void*)(uintptr_t)(x))
#endif

void orbit_main(void);


int main(int argc, char** argv) {
    arena = orbit_arena_create(64 * 1024 * 1024);
    orbit_main();
    return 0;
}
