#include "EXTERN.h"
#include "perl.h"

#ifdef DEBUG
#undef DEBUG
#endif

#define DEBUG 1

struct p_state {
  SV* buf;
  int bufpos;

  int strict_comment;

  CV* text_cb;
  CV* start_cb;
  CV* end_cb;
  CV* decl_cb;
  CV* com_cb;
};

void html_text(struct p_state* p_state, char* beg, char *end)
{
  if (beg == end)
    return;
  printf(">> text: [");
  while (beg < end) {
    putchar(*beg++);
  }
  putchar(']');
  putchar('\n');
}

int html_parse(struct p_state* p_state,
	       SV* chunk)
{
  char *s, *t, *end;
  STRLEN len;

#ifdef DEBUG
  {
    STRLEN len;
    char *s;

    printf("html_parse\n");
    if (p_state->buf) {
      s = SvPV(p_state->buf, len);
      printf("  buf   = [%s]\n", s);
    }
    if (chunk && SvOK(chunk)) {
      s = SvPV(chunk, len);
      printf("  chunk = [%s]\n", s);
    }
  }
#endif

  if (!chunk || !SvOK(chunk)) {
    /* EOF */
    if (p_state->buf) {
      /* flush it */
      STRLEN len;
      char *s = SvPV(p_state->buf, len);
      html_text(p_state, s, s+len);
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
    return;
  }


  if (p_state->buf) {
    sv_catsv(p_state->buf, chunk);
    s = SvPV(p_state->buf, len);
  }
  else {
    s = SvPV(chunk, len);
  }

  if (!len)
    return; /* nothing to do */

  t = s;
  end = s + len;

  while (1) {
  TEXT:
    while (s < end && *s != '<')
      s++;
    if (s != t) {
      if (*s == '<') {
	html_text(p_state, t, s);
	t = s;
      }
      else {
	s--;
	if (isSPACE(*s)) {
	  /* wait with white space at end */
	  while (s > t && isSPACE(*s))
	    s--;
	}
	else {
	  /* might be a chopped up entities/words */
	  while (s > t && !isSPACE(*s))
	    s--;
	  while (s > t && isSPACE(*s))
	    s--;
	}
	s++;
	html_text(p_state, t, s);
	t = s;
	break;
      }
    }

    if (end - s < 3)
      break;

    /* next char is known to be '<' */
    s++;

    switch (*s) {
    case '!':
      /* declaration or comment */
    case '/':
      /* end tag */
    case '?':
      /* processing instruction */
    default:
      if (isALPHA(*s)) {
	/* start tag */
      }
      else {
	/* non-conforming, i.e. treat it as text */
	goto TEXT;
      }
    }
  }

  if (s == end) {
    if (p_state->buf) {
      /* XXX it is probably more efficient to always have a buffer variable,
	 and then just mark it as unused by clearing SvOK
       */
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
  }
  else {
    /* need to keep rest in buffer */
    if (p_state->buf) {
      /* chop off some chars at the beginning */
      sv_chop(p_state->buf, s);
    }
    else {
      p_state->buf = newSVpv(s, end - s);
    }
  }
  return;
}



#if 1

int main(int argc, char** argv, char** env)
{
  struct p_state p;
  SV* sv1;
  SV* sv2;
  SV* sv3;
  SV* sv4;

  memset(&p, 0, sizeof(p));
  sv1 = newSVpv("bar <a href='foo'>foo</a>   ", 0);
  sv2 = newSVpv("<a href=\"", 0);
  sv3 = newSVpv("'>'\">bar</a>", 0);
  sv4 = newSVpv("foo &bar", 0);
  

  html_parse(&p, sv1);
  html_parse(&p, sv2);
  html_parse(&p, sv3);
  html_parse(&p, sv4);
  html_parse(&p, 0);
  html_parse(&p, 0);

  return 0;
}

#endif
